/*
 * Copyright (c) 2018-2020, NVIDIA CORPORATION.  All rights reserved.
 *
 * NVIDIA CORPORATION and its licensors retain all intellectual property
 * and proprietary rights in and to this software, related documentation
 * and any modifications thereto.  Any use, reproduction, disclosure or
 * distribution of this software and related documentation without an express
 * license agreement from NVIDIA CORPORATION is strictly prohibited.
 *
 * See COPYRIGHT.txt for license information
 */

#define CUMODULE_NAME "shmem_put_signal_ping_pong_latency.cubin"

#include <stdio.h>
#include <assert.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <unistd.h>
#include "utils.h"

#define MAX_MSG_SIZE 1 * 1024 * 1024
#define UNROLL 8

#if defined __cplusplus || defined NVSHMEM_BITCODE_APPLICATION
extern "C" {
#endif

#define PING_PONG(SC, SC_SUFFIX, SC_PREFIX)                                                   \
    __global__ void ping_pong##SC_SUFFIX(int *data_d, uint64_t *flag_d, int len, int pe,      \
                                         int iter) {                                          \
        int i, peer;                                                                          \
        int tid =                                                                             \
            (threadIdx.x * blockDim.y * blockDim.z + threadIdx.y * blockDim.z + threadIdx.z); \
        peer = !pe;                                                                           \
                                                                                              \
        for (i = 0; i < iter; i++) {                                                          \
            if (pe) {                                                                         \
                if (!tid) nvshmem_uint64_wait_until(flag_d, NVSHMEM_CMP_EQ, (i + 1));         \
                nvshmem##SC_PREFIX##_int_put_signal_nbi##SC_SUFFIX(                           \
                    data_d, data_d, len, flag_d, i + 1, NVSHMEM_SIGNAL_SET, peer);            \
            } else {                                                                          \
                nvshmem##SC_PREFIX##_int_put_signal_nbi##SC_SUFFIX(                           \
                    data_d, data_d, len, flag_d, i + 1, NVSHMEM_SIGNAL_SET, peer);            \
                if (!tid) nvshmem_uint64_wait_until(flag_d, NVSHMEM_CMP_EQ, (i + 1));         \
            }                                                                                 \
        }                                                                                     \
        nvshmem_quiet();                                                                      \
    }
PING_PONG(thread, , )
PING_PONG(warp, _warp, x)
PING_PONG(block, _block, x)

void test_ping_pong(void **arglist, CUfunction kernel, cudaStream_t stream) {
    int status;
    if (use_cubin) {
        CU_CHECK(cuLaunchCooperativeKernel(kernel, 1, 1, 1, 1, 1, 1, 0, stream, arglist));
    } else {
        status = nvshmemx_collective_launch((const void *)ping_pong, 1, 1, arglist, 0, stream);
        if (status != NVSHMEMX_SUCCESS) {
            fprintf(stderr, "shmemx_collective_launch failed %d \n", status);
            exit(-1);
        }
    }
}

#if defined __cplusplus || defined NVSHMEM_BITCODE_APPLICATION
}
#endif

int main(int argc, char *argv[]) {
    int mype, npes;
    uint64_t *flag_d = NULL;
    int *data_d = NULL;
    cudaStream_t stream;

    read_args(argc, argv);
    int iter = iters;
    int skip = warmup_iters;

    int array_size, i;
    void **h_tables;
    uint64_t *h_size_arr;
    double *h_lat;

    float milliseconds;
    cudaEvent_t start, stop;
    CUfunction test_cubin = NULL;

    init_wrapper(&argc, &argv);

    if (use_cubin) {
        init_cumodule(CUMODULE_NAME);
        init_test_case_kernel(&test_cubin, "ping_pong");
    }

    cudaEventCreate(&start);
    cudaEventCreate(&stop);

    mype = nvshmem_my_pe();
    npes = nvshmem_n_pes();

    if (npes != 2) {
        fprintf(stderr, "This test requires exactly two processes \n");
        goto finalize;
    }

    data_d = (int *)nvshmem_malloc(max_size);
    flag_d = (uint64_t *)nvshmem_malloc(sizeof(uint64_t));
    CUDA_CHECK(cudaMemset(data_d, 0, max_size));
    CUDA_CHECK(cudaMemset(flag_d, 0, sizeof(uint64_t)));

    array_size = max_size_log;
    alloc_tables(&h_tables, 2, array_size);
    h_size_arr = (uint64_t *)h_tables[0];
    h_lat = (double *)h_tables[1];

    CUDA_CHECK(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));

    nvshmem_barrier_all();

    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaGetLastError());

    if (mype == 0) {
        printf("Note: This test measures full round-trip latency\n");
    }

    i = 0;
    for (size_t size = min_size; size <= max_size; size *= step_factor) {
        int nelems = 0;
        nelems = size / sizeof(int);
        h_size_arr[i] = size;
        void *args_1[] = {&data_d, &flag_d, &nelems, &mype, &skip};
        void *args_2[] = {&data_d, &flag_d, &nelems, &mype, &iter};

        CUDA_CHECK(cudaMemset(flag_d, 0, sizeof(uint64_t)));
        CUDA_CHECK(cudaDeviceSynchronize());
        nvshmem_barrier_all();

        test_ping_pong(args_1, test_cubin, stream);
        CUDA_CHECK(cudaDeviceSynchronize());
        CUDA_CHECK(cudaMemset(flag_d, 0, sizeof(uint64_t)));
        nvshmem_barrier_all();

        cudaEventRecord(start, stream);
        test_ping_pong(args_2, test_cubin, stream);
        cudaEventRecord(stop, stream);

        /* give latency in us */
        CUDA_CHECK(cudaEventSynchronize(stop));
        cudaEventElapsedTime(&milliseconds, start, stop);
        h_lat[i] = (milliseconds * 1000) / iter;
        nvshmem_barrier_all();
        i++;
    }

    CUDA_CHECK(cudaDeviceSynchronize());

    if (mype == 0) {
        print_table_basic("shmem_put_ping_lat", "None", "size (Bytes)", "latency", "us", '-',
                          h_size_arr, h_lat, i);
    }
finalize:

    if (data_d) nvshmem_free(data_d);
    if (flag_d) nvshmem_free(flag_d);
    free_tables(h_tables, 2);
    finalize_wrapper();

    return 0;
}
