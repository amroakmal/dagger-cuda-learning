#include <cuda.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <iostream>
#include <cstdlib>

using namespace std;


const int LOW = -50;
const int HIGH = 50;

float get_random_number(float min, float max) {
    return LOW + static_cast <float> (rand()) / (static_cast <float> (RAND_MAX / (HIGH - LOW)));
}

/*
This kernel implements an online softmax operation on a matrix of size (M, N).
The softmax operation is performed on the last dimension of the matrix.

How this works:
In this, we handle each row with a block where the threads within one block work together
to process one row (max and norm factor). Each thread will process some elements
and will contains its local max and local norm in shared memory. Then, we perform reduction
operations to compute the final max and norm factor. Also, we compute maxes and norms
in one pass itself.
*/
__global__ void softmax_kernel(float* __restrict__ xd, float* __restrict__ resd, int M, int N) {
    // max and norm reduction will happen in shared memory (static)
    __shared__ float smem[1024];

    int row = blockIdx.x;
    int tid = threadIdx.x;

    printf("%d\n", blockIdx.x);

    // edge condition (we don't process further)
    if (row >= M) return;
    /**
     * Here, we are just getting the start index for this row that current block threads will be operating on
     */
    float* input_row = xd + row * N;
    float* output_row = resd + row * N;

    float local_max = -INFINITY;
    float local_norm = 0.0f;

    // compute local max and norm for each thread
    // and then finally have a sync barrier before moving on

    /**
     * Current block threads will work in parallel, each thread of them will calulate for elemnets reside at indices: {tid, tid + BLOCK_DIM,  tid + 2 * BLOCK_DIM}
     * 
     * This is helpful to achieve memory coalescing, where differnt threads operate on different elements, combine together for more efficient
     * execution for the operation they want with less memory transactions needed
     */
    for (int i = tid; i < N; i += blockDim.x) {
        float x = input_row[i];
        if (x > local_max) {
            local_norm *= expf(local_max - x);
            local_max = x;
        }
        local_norm += expf(x - local_max);
    }
    __syncthreads();

    // each thread will have its own local max
    // we store it in the tid of the shared memory

    /**
     * For each block (row) threads, each thread stores the maximum value it had among all values it operated on
     */
    smem[tid] = local_max;
    __syncthreads();

    // block-level reduction in O(log(N)) time over all threads
    // is faster than linear reduction over all threads
    for (int stride = blockDim.x / 2; stride > 0; stride /= 2) {
        if (tid < stride) {
            smem[tid] = max(smem[tid], smem[tid + stride]);
        }
        // sync barrier before next iteration to ensure correctness
        __syncthreads();
    }

    // the first element after max reduction from all threads
    // will contain the global max for the row
    float row_max = smem[0];
    __syncthreads();

    /**
     * This trick helps in calculating the norms in optimized fasion instead of 2 separate loops
     */
    smem[tid] = local_norm * expf(local_max - row_max);
    __syncthreads();

    // sum reduction similar to above for global norm factor
    for (int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
        if (tid < stride) {
            smem[tid] += smem[tid + stride];
        }
        __syncthreads();
    }
    float row_norm = smem[0];
    __syncthreads();

    // finally, compute softmax
    for (int i = tid; i < N; i += blockDim.x) {
        output_row[i] = expf(input_row[i] - row_max) / row_norm;
       printf("%f ", output_row[i]); 
    }

    printf("\n");
}

/*
Runs the online softmax kernel: `id = 2`
*/
void start_kernel_execution(float* mat, int M, int N) {
    // grid size and block size for this kernel
    // change as necessary
    dim3 block_size(M);
    dim3 grid_size(M);

    float *matd, *resd;

    if (cudaMalloc(&matd, M * N * sizeof(float)) != cudaSuccess ||
        cudaMalloc(&resd, M * N * sizeof(float)) != cudaSuccess) {
        std::cerr << "Error: cudaMalloc failed." << std::endl;
        return;
    }

    // Copy matrix from host to device
    if (cudaMemcpy(matd, mat, M * N * sizeof(float), cudaMemcpyHostToDevice) != cudaSuccess) {
        std::cerr << "Error: cudaMemcpy failed." << std::endl;
        cudaFree(matd);
        cudaFree(resd);
        return;
    }

    softmax_kernel<<<grid_size, block_size>>>(matd, resd, M, N);

    cudaFree(matd);
    cudaFree(resd);
}

int main() {
    int M = 10;
    int N = 20;
    int matsize = M * N;
    int totalsize = matsize * sizeof(float);

    // allocate and initialize host matrix
    float* mat = (float*)malloc(totalsize);
    for (int i = 0; i < matsize; i++) {
        mat[i] = get_random_number(-10, 10);
    }

    start_kernel_execution(mat, M, N);

    free(mat);
}
