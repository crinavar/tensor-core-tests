
#include <cuda.h>
#include <mma.h>
#include <stdio.h>
#include <iostream>
#include <iomanip>
#include <string>
#include <map>
#include <random>
#include <cmath>
#define REAL float
#define TCSIZE 16
#define TCSQ 256
#define PRINTLIMIT 2560
#define WARPSIZE 32
#define DIFF (BSIZE<<3)
#include "kernel.cuh"

//#define DEBUG

void init_normal(REAL *m, long n, const int val, int seed){
    //srand(seed);
    std::mt19937 gen{seed};
    std::normal_distribution<> d{0,1};
    for(long k=0; k<n; ++k){
        m[k] = (float) d(gen); //(REAL) rand()/(((REAL)RAND_MAX)*1000);
        //printf("%f\n",(float)m[k]);
    }
}

void init_uniform(REAL *m, long n, const int val, int seed){
    std::mt19937 gen{seed};
    std::uniform_real_distribution<> d(0, 1);
    for(long k=0; k<n; ++k){
        m[k] = (float) d(gen);//(REAL) rand()/(((REAL)RAND_MAX)*1000);
        //printf("%f\n",(float)m[k]);
    }
}

double gold_reduction(REAL *m, long n){
    double sum = 0.0f;
    for(long k=0; k<n; ++k){
        sum += m[k];
    }
    return sum;
}

void printarray(REAL *m, int n, const char *msg){
    printf("%s:\n", msg);
    for(int j=0; j<n; ++j){
        printf("%8.4f\n", m[j]);
    }
}

void printmats(REAL *m, int n, const char *msg){
    long nmats = (n + 256 - 1)/TCSQ;
    printf("%s:\n", msg);
    long index=0;
    for(int k=0; k<nmats; ++k){
        printf("k=%i\n", k);
        int off = k*TCSIZE*TCSIZE;
        for(int i=0; i<TCSIZE; ++i){
            for(int j=0; j<TCSIZE; ++j){
                if(index < n){
                    printf("%8.4f ", m[off + i*TCSIZE + j]);
                }
                else{
                    printf("%8.4f ", -1.0f);
                }
                index += 1;
            }
            printf("\n");
        }
    }
}

int main(int argc, char **argv){
    // params
    if(argc != 8){
        fprintf(stderr, "run as ./prog dev n factor_ns seed REPEATS dist method\nmethod:\
        \n0 -> shuffle\
        \n1 -> theory recursive\
        \n2 -> tensor_shuffle\
        \n3 -> mixed\n\n");
        exit(EXIT_FAILURE);
    }
    int dev = atoi(argv[1]);
    long on = atoi(argv[2]);
    long n = on;
    float factor_ns = atof(argv[3]);
    int seed = atoi(argv[4]);
    int REPEATS = atoi(argv[5]);
    int dist = atoi(argv[6]);
    int method = atoi(argv[7]);

#ifdef DEBUG
    const char* methods[5] = {"WARP-SHUFFLE", "THEORY RECURRENCE (CG)", "CHAINED MMAs", "SPLIT", "THEORY RECURRENCE (iterative kernels)"};
    printf("\n\
            ***************************\n\
            method=%s\n\
            dev = %i\n\
            n=%i\n\
            factor_ns=%f\n\
            prng_seed = %i\n\
            KERNEL_REPEATS = %i\n\
            TCSIZE=%i\n\
            R = %i\n\
            BSIZE = %i\n\
            ***************************\n\n", methods[method], dev, n, factor_ns, seed, REPEATS, TCSIZE, R, BSIZE);
#endif
    
    // set device
    cudaSetDevice(dev);

    // mallocs
    half z = 0.01;
    REAL *A;
    REAL *Ad;
    half *Adh;
    float *outd;
    half *outd_m0;
    float *out;

    A = (REAL*)malloc(sizeof(REAL)*n);
    out = (float*)malloc(sizeof(float)*1);
    cudaMalloc(&Ad, sizeof(REAL)*n);
    cudaMalloc(&Adh, sizeof(half)*n);
    cudaMalloc(&outd, sizeof(float)*1);
    cudaMalloc(&outd_m0, sizeof(half)*n);

    //init(A, n, 1, seed);
    if(dist == 0){
        init_normal(A, n, 1, seed);
    }
    else{
        init_uniform(A, n, 1, seed);
    }

    //printmats(A, n, "[after] mat A:");
    cudaMemcpy(Ad, A, sizeof(REAL)*n, cudaMemcpyHostToDevice);
    convertFp32ToFp16 <<< (n + 256 - 1)/256, 256 >>> (Adh, Ad, n);
    cudaDeviceSynchronize();
    
    //printmats(A, n, "[after] mat A:");
    
    dim3 block, grid;
    //block = dim3(TCSIZE*2, 1, 1);
    //grid = dim3((n + 256 - 1)/TCSQ, 1, 1);
    //int bs = BSIZE/(TCSIZE*2);
    int bs = BSIZE/WARPSIZE;
    
    //block = dim3(TCSIZE*2*bs, 1, 1);
    //grid = dim3((n + (TCSQ*bs*(R)) - 1)/(TCSQ*bs*(R)), 1, 1);
    //printf("grid (%i, %i, %i)    block(%i, %i, %i)\n", grid.x, grid.y, grid.z, block.x, block.y, block.z);
   
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start);
    
    if(method == 0){
        #ifdef DEBUG
            printf("%s (BSIZE = %i)\n", methods[method], BSIZE);
        #endif
        block = dim3(BSIZE, 1, 1);
        grid = dim3((n + BSIZE -1)/BSIZE, 1, 1);
        for(int i=0; i<REPEATS; ++i){
            cudaMemset(outd, 0, sizeof(REAL)*1);
            kernel_reduction_shuffle<<<grid, block>>>(Adh, outd, n);  CUERR;
            cudaDeviceSynchronize();
        }
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        cudaMemcpy(out, outd, sizeof(float)*1, cudaMemcpyDeviceToHost);
    }
    else if(method == 1){
        #ifdef DEBUG
            printf("%s (BSIZE =%i)\n", methods[method], BSIZE);
        #endif
        if(n<=524288){
            //printf("reduction_tc_theory (cooperative groups)\n");
            void *kernelArgs[3];
            kernelArgs[0]= (void*)&Adh;
            kernelArgs[1]= (void*)&outd_m0;
            kernelArgs[2]= (void*)&n;
            block = dim3(BSIZE, 1, 1);
            grid = dim3((n + DIFF -1)/(DIFF),1,1) ;//dim3((n + 255)/TCSQ, 1, 1);
            //printf("grid (%i, %i, %i)    block(%i, %i, %i)\n", grid.x, grid.y, grid.z, block.x, block.y, block.z);
            //kernel_reduction_tc_theory<<<grid, block>>>(Adh, outd_m0, n);
            for(int i=0; i<REPEATS; ++i){
                cudaMemset(outd_m0, 0, sizeof(REAL)*1);
                cudaLaunchCooperativeKernel((void *) kernel_reduction_tc_theory,grid,block,kernelArgs,NULL);  CUERR;
                cudaDeviceSynchronize();
            }
            cudaEventRecord(stop);
            cudaEventSynchronize(stop);
            cudaMemcpy(&z, outd_m0, sizeof(half)*1, cudaMemcpyDeviceToHost);
            *out = (float)z;
            //cudaMemcpy(out, outd, sizeof(half)*1, cudaMemcpyDeviceToHost);
            /*n = ((n + TCSQ-1)/TCSQ) * TCSQ;
            grid = dim3((n + TCSQ-1)/TCSQ, 1, 1);
            while(n > 1){
                kernel_reduction_tc_theory<<<grid, block>>>(outd_m0, outd_m0, n);
                // para n generico: actualizar n --> nuevo n 'paddeado' y mas chico
                n = ((n + TCSQ-1)/TCSQ) * TCSQ;
                // para n potencias de TCSQ 
                //n = n/256;
                // n/TCSQ
                grid = dim3((n + TCSQ-1)/TCSQ, 1, 1);
                //printf("grid (%i, %i, %i)    block(%i, %i, %i)\n", grid.x, grid.y, grid.z, block.x, block.y, block.z);
                //printf("n: %i, grid: %i, %i, %i\n",n,grid.x,grid.y,grid.z);
                //printmats(A, n, "[after] mat D:");
            }
            n=on;
            //grid = dim3((n + 256 - 1)/TCSQ, 1, 1);
            //cudaMemcpy(Ad, A, sizeof(REAL)*n, cudaMemcpyDeviceToHost);    
            //printf("D: %f\n",(float)A[0]);
            */
        }
        else{
            printf("0,0,0,0,0\n");
            free(A);
            free(out);
            cudaFree(Ad);
            cudaFree(Adh);
            cudaFree(outd);
            //*out = 0.0f;
            exit(EXIT_SUCCESS);
        }
    }
    if(method == 2){
        #ifdef DEBUG
            printf("%s (R=%i, BSIZE = %i)\n", methods[method], R, BSIZE);
        #endif
        //printf("reduction_tc_blockshuffle\n");
        //block = dim3(TCSIZE*2*bs, 1, 1);
        block = dim3(BSIZE, 1, 1);
        grid = dim3((n + (TCSQ*bs*(R)) - 1)/(TCSQ*bs*(R)), 1, 1);
        #ifdef DEBUG
            printf("grid (%i, %i, %i)    block(%i, %i, %i)\n", grid.x, grid.y, grid.z, block.x, block.y, block.z);
        #endif
        for(int i=0; i<REPEATS; ++i){
            cudaMemset(outd, 0, sizeof(REAL)*1);
            kernel_reduction_tc_blockshuffle<<<grid, block>>>(Adh, outd, n,bs);
            cudaDeviceSynchronize();
        }
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        cudaMemcpy(out, outd, sizeof(float)*1, cudaMemcpyDeviceToHost);
    }
    if(method == 3){
        #ifdef DEBUG
            printf("%s (BSIZE = %i)\n", methods[method], BSIZE);
        #endif
        block = dim3(BSIZE, 1, 1);
        long nsh = (long)ceil(factor_ns*n);
        long ntc = n - nsh;
        int ns_blocks = (nsh + BSIZE-1)/BSIZE;
        int tc_blocks = (ntc + TCSQ*bs - 1)/(TCSQ*bs);
        grid = dim3(tc_blocks + ns_blocks, 1, 1);
        #ifdef DEBUG
            printf("ns_blocks %i, tc_blocks %i\n", ns_blocks, tc_blocks);
            printf("grid (%i, %i, %i)    block(%i, %i, %i)  DIFF %i\n", grid.x, grid.y, grid.z, block.x, block.y, block.z,DIFF);
        #endif
        for(int i=0; i<REPEATS; ++i){
            cudaMemset(outd, 0, sizeof(REAL)*1);
            kernel_reduction_tc_mixed<<<grid, block>>>(n, Adh, outd, tc_blocks, ns_blocks);  CUERR;
            cudaDeviceSynchronize();
        }
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        cudaMemcpy(out, outd, sizeof(float)*1, cudaMemcpyDeviceToHost);
    }        
    else if(method == 4){
        #ifdef DEBUG
            printf("%s (BSIZE =%i)\n", methods[method], BSIZE);
        #endif
        block = dim3(BSIZE, 1, 1);
        grid = dim3((n + TCSQ*bs-1)/(TCSQ*bs), 1, 1);
        int dn = ((n + TCSQ-1)/TCSQ) * TCSQ;
        int rlimit = 1 << 1;
        while(dn >= rlimit){
            printf("executing recurrence for dn=%i >= rlimit =%i\n", dn, rlimit);
            printf("       grid (%i, %i, %i)    block(%i, %i, %i)\n\n\n", grid.x, grid.y, grid.z, block.x, block.y, block.z);
            //kernel_reduction_tc_theory<<<grid, block>>>(outd_m0, outd_m0, dn);
            // para n generico: actualizar n --> nuevo n 'paddeado' y mas chico
            dn = (dn + TCSQ-1)/TCSQ;
            grid = dim3((dn + TCSQ*bs-1)/(TCSQ*bs), 1, 1);
            //printmats(A, dn, "[after] mat D:");
        }
        //grid = dim3((n + 256 - 1)/TCSQ, 1, 1);
        //cudaMemcpy(Ad, A, sizeof(REAL)*n, cudaMemcpyDeviceToHost);    
        //printf("D: %f\n",(float)A[0]);
        
    }
    float time = 0.0f;
    cudaEventElapsedTime(&time, start, stop);
    double cpusum = gold_reduction(A, n);

    #ifdef DEBUG
        //printf("gpu: %f\ncpu: %f \ndiff = %f (%f%%)\n", (float)*out, cpusum, fabs((float)*out - cpusum), 100.0f*fabs((float)*out - cpusum)/cpusum);
        /*/printf("%f \n",(n/(time/1000.0f))/1000000000.0f);
        printf("%f\n", time/(REPEATS));*/
    #endif
        printf("%f,%f,%f,%f,%f\n",time/(REPEATS),(float)*out,cpusum,fabs((float)*out - cpusum),fabs(100.0f*fabs((float)*out - cpusum)/cpusum));
    #ifdef DEBUG
        /*if(n < PRINTLIMIT){
           printmats(A, on, "A final:");
        }*/
        //printarray(A, 1, "D_final: ");
        //printf("%i\n",DIFF);
    #endif
    free(A);
    free(out);
    cudaFree(Ad);
    cudaFree(Adh);
    cudaFree(outd);
    exit(EXIT_SUCCESS);
}

