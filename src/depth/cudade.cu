
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <stdio.h>
#include <math.h>
#include <float.h>
#include <stdlib.h>
#include <time.h>

#define E_PI 3.1415926535897932384626433832795028841971693993751058209749445923078164062


cudaError_t addWithCuda(int *c, const int *a, const int *b, unsigned int size);

#define PROFILE 0

__global__ void addKernel(int *c, const int *a, const int *b)
{
    int i = threadIdx.x;
    c[i] = a[i] + b[i];
}

__device__ static void GetPhase(const float* d, float* phase, float* amplitude, float* offset)
{
    // See https://math.stackexchange.com/questions/118526/fitting-a-sine-wave-of-known-frequency-through-three-points
    float c = (d[0] + d[2]) / 2.0f;
    *offset = c;
    //float a = sqrtf(powf(d[0] - c, 2.0f) + powf(d[1] - c, 2.0f));
    //*amplitude = a;
    float b = atan2f(d[0] - c, d[1] - c);
    *phase = b;
}


__device__ float GetNFOVData(int x, int y, int frame, const unsigned char* image)
{
    const int frame_width = 640;
    const int frame_height = 576;
    const int frame_stride = frame_width * 8 / 5;
    int offset = ((frame + 1) % 4) * frame_stride / 4;
    int block_of_8 = x / 5;
    int line_idx = offset + block_of_8 * 8 + x % 5;
    int idx = y * frame_stride + frame * frame_height * frame_stride + line_idx;

    int d = (int)image[idx];
    if (d >= 64)
        d = 64 - d;
    return d;
}

__device__ static inline float GetNFOVDistance(const float* phases, float* err)
{
    /* Calibration gives us:
        d1 = 0.734 * phase1 - 0.300 
        d2 = 0.778 * phase2 - 0.150
        d3 = 2.866 * phase3 - 1.053
        
        For max dist of 3.86m (as per data sheet), we get
        max phase1 = 5.66 * 2pi
        max phase2 = 5.42 * 2pi
        max phase3 = 1.71 * 2pi */

    const int f1n = 5;
    const int f2n = 5;
    const int f3n = 1;

    float best_err = FLT_MAX;
    float best_dist = 0.0f;

    int best_i = 0;
    int best_j = 0;
    int best_k = 0;

    // brute force algorithm as per https://medium.com/chronoptics-time-of-flight/phase-wrapping-and-its-solution-in-time-of-flight-depth-sensing-493aa8b21c42
    for (int k = 0; k <= f3n; k++)
    {
        for (int j = 0; j <= f2n; j++)
        {
            for (int i = 0; i <= f1n; i++)
            {
                //float d1 = (phases[0] + (float)i * 2.0f * E_PI) / 2.0f / f1;
                //float d2 = (phases[1] + (float)j * 2.0f * E_PI) / 2.0f / f2;
                //float d3 = (phases[2] + (float)k * 2.0f * E_PI) / 2.0f / f3;

                float d1 = 0.734f / 2.0f / E_PI * (phases[0] + (float)i * 2.0f * E_PI) - 0.300f;
                float d2 = 0.778f / 2.0f / E_PI * (phases[1] + (float)j * 2.0f * E_PI) - 0.357f;
                float d3 = 2.866f / 2.0f / E_PI * (phases[2] + (float)k * 2.0f * E_PI) - 1.053f;

                float d_mean = (d1 + d2 + d3) / 3.0f;
                //float d_var = (powf(d1 - d_mean, 2.0f) + powf(d2 - d_mean, 2.0f) + powf(d3 - d_mean, 2.0f)) / 3.0f;
                //float d_var = fabsf(d1 - d_mean) + fabsf(d2 - d_mean) + fabsf(d3 - d_mean);
                float d_var = ((d1 - d_mean) * (d1 - d_mean) + (d2 - d_mean) * (d2 - d_mean) + (d3 - d_mean) * (d3 - d_mean)) / 3.0f;
                //printf("%i,%i,%i: %f,%f,%f (%f)\n",
                //    i, j, k, d1, d2, d3, sq_err);
                // TODO: profile to see which of these is best
#if 0
                if (d_var < best_err)
                {
                    best_err = d_var;
                    best_dist = d_mean;
                    best_i = i;
                    best_j = j;
                    best_k = k;
                }
#endif

#if 1
                best_dist = d_var < best_err ? d_mean : best_dist;
                best_i = d_var < best_err ? i : best_i;
                best_j = d_var < best_err ? j : best_j;
                best_k = d_var < best_err ? k : best_k;
                best_err = d_var < best_err ? d_var : best_err;
#endif
            }
        }
    }

    if (err)
    {
        *err = best_err;
    }

    //best_dist *= 300.0f / 2.0f / E_PI;      // c / 10e6 to account for freq in MHz

    (void)best_i;
    (void)best_j;
    (void)best_k;
    //printf("%i,%i,%i: %f (%f)\n", best_i, best_j, best_k, best_dist, best_err);

    return best_dist;
}

#if PROFILE
#define PROFILE_START(a) unsigned int pstart ## a, pend ## a; pstart ## a = clock();
#define PROFILE_END(a) pend ## a = clock(); dev_times ## a ## [outidx] = pend ## a - pstart ## a;
#else
#define PROFILE_START(a)
#define PROFILE_END(a)
#endif


__global__ void NFOVUnbinnedKernel(unsigned short int* depth_out,
    unsigned short int* ir_out,
    const unsigned char* data
#if PROFILE    
    , unsigned int *dev_times1, unsigned int *dev_times2, unsigned int *dev_times3
#endif
    )
{
    int outidx = threadIdx.x + blockIdx.x * blockDim.x;

    const int frame_width = 640;

    int x = outidx % frame_width;
    int y = outidx / frame_width;

    float phases[3];
    float offsets[3];
    float amplitudes[3];
    float d[9];

    PROFILE_START(1);
    PROFILE_START(2);
    for (int i = 0; i < 9; i++)
    {
        d[i] = GetNFOVData(x, y, i, data);
    }

    for (int i = 0; i < 3; i++)
    {
        GetPhase(&d[i * 3], &phases[i], &amplitudes[i], &offsets[i]);
    }
    PROFILE_END(2);

    // Apply a fiddle factor based upon experimentation to account for time delay
    //  between imaging each column of the IR image
    phases[0] = fmodf(phases[0] - 2.7f * (float)x / 200.0f, E_PI * 2.0f);
    phases[1] = fmodf(phases[1] - 2.55f * (float)x / 200.0f, E_PI * 2.0f);
    phases[2] = fmodf(phases[2] - 1.05f * (float)x / 200.0f, E_PI * 2.0f);
    if (phases[0] < 0.0f) phases[0] += E_PI * 2.0f;
    if (phases[1] < 0.0f) phases[1] += E_PI * 2.0f;
    if (phases[2] < 0.0f) phases[2] += E_PI * 2.0f;

    PROFILE_START(3);
    float dist = GetNFOVDistance(phases, NULL);
    PROFILE_END(3);
    float irf = fabsf((offsets[0] + offsets[1] + offsets[2]) / 3.0f / dist / dist * 1000.0f);

    unsigned short int depth_val = (unsigned short int)(dist * 1000.0f); // mm distance
    unsigned short int ir_val = (unsigned short int)irf;

    depth_out[outidx] = depth_val;
    ir_out[outidx] = ir_val;

    PROFILE_END(1);
}

// buffers to hold device data
unsigned char* dev_data;
unsigned short* dev_ir_out;
unsigned short* dev_depth_out;

unsigned int* dev_times1;
unsigned int* dev_times2;
unsigned int* dev_times3;

// buffer sizes
const int NFOVUnbinned_in_count = 1024 * 576 * 9;
const int NFOVUnbinned_out_count = 640 * 576;

const int nthreads = 128;

extern "C" {

// Function to call the kernel
void RunNFOVUnbinnedCalculation(unsigned short int* depth_out,
    unsigned short int* ir_out,
    const unsigned char* data)
{
    // TODO: add error checking here
    cudaError_t cudaStatus = cudaMemcpy(dev_data, data, NFOVUnbinned_in_count * sizeof(unsigned char), cudaMemcpyHostToDevice);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaMemcpy failed!");
        return;
    }

    NFOVUnbinnedKernel <<<NFOVUnbinned_out_count / nthreads, nthreads>>> (dev_depth_out, dev_ir_out, dev_data
#if PROFILE
        , dev_times1, dev_times2, dev_times3
#endif
        );

    // Check for any errors launching the kernel
    cudaStatus = cudaGetLastError();
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "addKernel launch failed: %s\n", cudaGetErrorString(cudaStatus));
        return;
    }

    cudaStatus = cudaMemcpy(depth_out, dev_depth_out, NFOVUnbinned_out_count * sizeof(unsigned short), cudaMemcpyDeviceToHost);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaMemcpy failed!");
        return;
    }
    cudaStatus = cudaMemcpy(ir_out, dev_ir_out, NFOVUnbinned_out_count * sizeof(unsigned short), cudaMemcpyDeviceToHost);
    if (cudaStatus != cudaSuccess) {
        fprintf(stderr, "cudaMemcpy failed!");
        return;
    }

#if PROFILE
    unsigned int* times1 = (unsigned int*)malloc(NFOVUnbinned_out_count * sizeof(unsigned int));
    unsigned int* times2 = (unsigned int*)malloc(NFOVUnbinned_out_count * sizeof(unsigned int));
    unsigned int* times3 = (unsigned int*)malloc(NFOVUnbinned_out_count * sizeof(unsigned int));
    cudaMemcpy(times1, dev_times1, NFOVUnbinned_out_count * sizeof(unsigned int), cudaMemcpyDeviceToHost);
    cudaMemcpy(times2, dev_times2, NFOVUnbinned_out_count * sizeof(unsigned int), cudaMemcpyDeviceToHost);
    cudaMemcpy(times3, dev_times3, NFOVUnbinned_out_count * sizeof(unsigned int), cudaMemcpyDeviceToHost);

    unsigned int times1_worst = 0;
    unsigned int times2_worst = 0;
    unsigned int times3_worst = 0;

    for (int i = 0; i < NFOVUnbinned_out_count; i++)
    {
        if (times1[i] >= times1_worst) times1_worst = times1[i];
        if (times2[i] >= times2_worst) times2_worst = times2[i];
        if (times3[i] >= times3_worst) times3_worst = times3[i];
    }

    printf("t1: %i, t2: %i, t3: %i\n", times1_worst, times2_worst, times3_worst);

    free(times1);
    free(times2);
    free(times3);
#endif
}

// Init function
void InitNFOVUnbinnedCalculation()
{
    cudaSetDevice(0);
    cudaMalloc(&dev_data, NFOVUnbinned_in_count * sizeof(unsigned char));
    cudaMalloc(&dev_ir_out, NFOVUnbinned_out_count * sizeof(unsigned short int));
    cudaMalloc(&dev_depth_out, NFOVUnbinned_out_count * sizeof(unsigned short int));

#ifdef PROFILE
    cudaMalloc(&dev_times1, NFOVUnbinned_out_count * sizeof(unsigned int));
    cudaMalloc(&dev_times2, NFOVUnbinned_out_count * sizeof(unsigned int));
    cudaMalloc(&dev_times3, NFOVUnbinned_out_count * sizeof(unsigned int));
#endif
}

// Dealloc function
void DeinitNFOVUnbinnedCalculation()
{
    if (dev_data)
    {
        cudaFree(dev_data);
        dev_data = NULL;
    }
    if (dev_ir_out)
    {
        cudaFree(dev_ir_out);
        dev_ir_out = NULL;
    }
    if (dev_depth_out)
    {
        cudaFree(dev_depth_out);
        dev_depth_out = NULL;
    }

#if PROFILE
    if (dev_times1)
    {
        cudaFree(dev_times1);
        dev_times1 = NULL;
    }
    if (dev_times2)
    {
        cudaFree(dev_times2);
        dev_times2 = NULL;
    }
    if (dev_times3)
    {
        cudaFree(dev_times3);
        dev_times3 = NULL;
    }
#endif

}

}
