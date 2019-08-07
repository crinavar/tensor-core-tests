//uso de half.h de CUB
//nota: pierde info

/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2018, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/******************************************************************************
 * Simple example of DeviceReduce::Sum().
 *
 * Sums an array of int keys.
 *
 * To compile using the command line:
 *   nvcc -arch=sm_XX example_device_reduce.cu -I../.. -lcudart -O3
 *
 ******************************************************************************/

// Ensure printing of CUDA runtime errors to console
#define CUB_STDERR

#include <stdio.h>
#include <cuda_fp16.h>
#include <time.h>
#include <sys/time.h>

#include <cub/util_allocator.cuh>
#include <cub/device/device_reduce.cuh>

#include "../../test/test_util.h"
//#include "../../test/half.h"

using namespace cub;

#define TAM_WARP 32
//---------------------------------------------------------------------
// Globals, constants and typedefs
//---------------------------------------------------------------------

bool                    g_verbose = false;  // Whether to display input/output to console
CachingDeviceAllocator  g_allocator(true);  // Caching allocator for device memory
int g_timing_iterations = 100;


//---------------------------------------------------------------------
// Test generation
//---------------------------------------------------------------------

/**
 * Initialize problem
 */


//el primer warp pasa en el device los datos desde float a half
__global__ void Float2HalfKernelWarp(
    int         TILE_SIZE,
    half         *d_in_half,
    float         *d_in)
{
    int i;
    int id = threadIdx.x + (blockDim.x * blockIdx.x);

    if(id < TAM_WARP)
    {
        //versión de CUDA >= 9.2 para que se pueda usar el tipo half en host y asi poder optimizar mandando directamente el half a device.
        for(i=id; i < TILE_SIZE; i += TAM_WARP){
            d_in_half[i] = __float2half(d_in[i]);
        }
    }

}

//kernel para copiar de half a float.
__global__ void Half2FloatKernel(
    float *b,
    half *a)
{
    *b= __half2float(*a);

}


float Initialize(float *h_in, int num_items)
{
    float inclusive = 0.0;

    for (int i = 0; i < num_items; ++i)
    {
        h_in[i]= (float)rand()/(float)(RAND_MAX);
        inclusive += h_in[i];

    }
    return inclusive;
}



//---------------------------------------------------------------------
// Main
//---------------------------------------------------------------------

/**
 * Main
 */
int main(int argc, char** argv)
{
    if(argv[1]==""){
        printf("\fNumber of items must be given by console\n");
        return 0;
    }
    int num_items = atoi(argv[1]);
    srand(time(NULL));
    

    // Initialize command line
    CommandLineArgs args(argc, argv);
    g_verbose = args.CheckCmdLineFlag("v");
    args.GetCmdLineArgument("n", num_items);

    // Print usage
    if (args.CheckCmdLineFlag("help"))
    {
        printf("%s "
            "[--n=<input items> "
            "[--device=<device-id>] "
            "[--v] "
            "\n", argv[0]);
        exit(0);
    }

    // Initialize device
    CubDebugExit(args.DeviceInit());

    printf("cub::DeviceReduce::Sum() %d items (%d-byte elements)\n", num_items, (int) sizeof(half));
    fflush(stdout);



    // Allocate host arrays
    float* h_in = new float[num_items];
    float h_out=0.0;
    
        // Allocate problem device arrays
    float *d_in = NULL;
    half *d_in_half           = NULL;
    
    //cudaMalloc((void**)&d_in,          sizeof(float) * num_items);
    //cudaMalloc((void**)&d_in_half,          sizeof(half) * num_items);
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_in, sizeof(float) * num_items));
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_in_half, sizeof(half) * num_items));



    // Allocate device output array
    float *d_out = NULL;
    half *d_out_half = NULL;
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_out, sizeof(float) * 1));
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_out_half, sizeof(half) * 1));

    // Request and allocate temporary storage
    void            *d_temp_storage = NULL;
    size_t          temp_storage_bytes = 0;








    // lectura de archivo en host 
     float  h_reference= Initialize(h_in,num_items);
    printf("\tSuma en host con tipo half:%f\n",h_reference);



    //copia de input a device (float a float)
    CubDebugExit(cudaMemcpy(d_in, h_in, sizeof(float) * num_items, cudaMemcpyHostToDevice));

    //llamado a kernel para pasar de float a half en device
    Float2HalfKernelWarp<<<1,32>>>(
    num_items,
    d_in_half,
    d_in);



    CubDebugExit(DeviceReduce::Hsum(d_temp_storage, temp_storage_bytes, d_in_half, d_out_half, num_items));
    CubDebugExit(g_allocator.DeviceAllocate(&d_temp_storage, temp_storage_bytes));



    // Run
    CubDebugExit(DeviceReduce::Hsum(d_temp_storage, temp_storage_bytes,d_in_half, d_out_half, num_items));



    // Check for correctness (and display results, if specified)
    //int compare = CompareDeviceResults(&h_reference, d_out, 1, g_verbose, g_verbose);
    //printf("\t%s", compare ? "FAIL" : "PASS");
    //AssertEquals(0, compare);

    //cudaMemcpy(&h_out_half, d_out, sizeof(half_t), cudaMemcpyDeviceToHost);


    //paso del resultado final de half a float
    Half2FloatKernel<<<1,1>>>(
    d_out,
    d_out_half);


    //copia del resultado final desde device a host (float a float)
    cudaMemcpy(&h_out, d_out, sizeof(float), cudaMemcpyDeviceToHost);

    printf("\tsuma de half en device: %f\n\n",h_out);


    // Run this several times and average the performance results
    GpuTimer    timer;
    float       elapsed_millis          = 0.0;

    printf("\tnumero de pruebas para tiempo promedio: %d\n", g_timing_iterations);

     for (int i = 0; i < g_timing_iterations; ++i)
    {
        // Copy problem to device
        CubDebugExit(cudaMemcpy(d_in, h_in, sizeof(float) * num_items, cudaMemcpyHostToDevice));
        timer.Start();

        // Run aggregate
        CubDebugExit(DeviceReduce::Hsum(d_temp_storage, temp_storage_bytes,d_in_half, d_out_half, num_items));
        timer.Stop();
        elapsed_millis += timer.ElapsedMillis();
    }


    // Check for kernel errors and STDIO from the kernel, if any
    CubDebugExit(cudaPeekAtLastError());
    CubDebugExit(cudaDeviceSynchronize());

    // Display timing results
    float avg_millis            = elapsed_millis / g_timing_iterations;

    printf("\ttiempo promedio (mili segundos): %.4f\n", avg_millis);

    // Cleanup
    if (h_in) delete[] h_in;
    if (d_in) CubDebugExit(g_allocator.DeviceFree(d_in));
    if (d_out) CubDebugExit(g_allocator.DeviceFree(d_out));
    if (d_temp_storage) CubDebugExit(g_allocator.DeviceFree(d_temp_storage));

    printf("\n\n");

    return 0;
}


