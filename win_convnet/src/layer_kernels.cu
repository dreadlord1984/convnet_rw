/* 
 * Copyright (c) 2011, Alex Krizhevsky (akrizhevsky@gmail.com)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * 
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
 * EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <assert.h>

#include <layer_kernels.cuh>

/*
 * E = -log(y_t)
 * probs:           (numOut, numCases)
 * labels:          (1, numCases)
 * maxProbs:        (1, numCases)
 * labelLogProbs:   (1, numCases)   (*out)
 * correctProbs:    (1, numCases)   (*out)
 * 
 * target:          (1, numCases)
 */
__global__ void kLogregCost(float* probs, float* labels, float* maxProbs, float* labelLogProbs, float* correctProbs,
                            const int numCases, const int numOut) {
    const int tx = blockIdx.x * LOGREG_ERR_THREADS_X + threadIdx.x;

    if (tx < numCases) {
        const int label = int(labels[tx]);
        const float maxp = maxProbs[tx];
        const float labelp = probs[label * numCases + tx];  
        labelLogProbs[tx] = __logf(labelp);
        
        /*
         * Compute the probability of guessing the correct case if you take the most-probable label.
         * 
         * This is done like this:
         * 
         * - If the most probable label is not equal to the true label, then the probability is zero.
         * - Otherwise, the probability is 1 / (number of labels whose probability is equal to the maximum).
         * 
         * This is certainly overkill -- in practice, it's just about impossible for two labels to get assigned
         * maximum probability. But it's a safety measure to prevent over-estimating your accuracy.
         * Though it could never happen in reality. Well it could. But it wouldn't. Cool?
         */
        if (labelp != maxp) {
            correctProbs[tx] = 0;
        } else {
            int numMax = 0;
            for (int i = 0; i < numOut; i++) {
                numMax += probs[i * numCases + tx] == maxp;
            }
            correctProbs[tx] = 1.0f / float(numMax);
        }
    }
}

__global__ void kL2SVMCost(float* acts, float* labels, float* maxActs, float* acts_out, float* correctPreds,
                            const int numCases, const int numOut) {
    const int tx = blockIdx.x * LOGREG_ERR_THREADS_X + threadIdx.x;

    if (tx < numCases) {
        const int label = int(labels[tx]);
        const float max_svm = maxActs[tx];
        const float svm_label_value = acts[label * numCases + tx];  
		const float max_label_val = fmaxf(1-svm_label_value, 0);
        acts_out[tx] = max_label_val*max_label_val;

        if (svm_label_value != max_svm) {
            correctPreds[tx] = 0;
        } else {
            int numMax = 0;
            for (int i = 0; i < numOut; i++) {
                numMax += acts[i * numCases + tx] == max_svm;
            }
            correctPreds[tx] = 1.0f / float(numMax);
        }
    }
}



__global__ void kRLogCost(float* probs, float* labels, float* maxProbs, float* labelLogProbs, float* correctProbs,
						  float* probWeights, const float p_pow, const int numCases, const int numOut) {
    const int tx = blockIdx.x * LOGREG_ERR_THREADS_X + threadIdx.x;

    if (tx < numCases) {
        const int label = int(labels[tx]);
        const float maxp = maxProbs[tx];
        const float labelp = probs[label * numCases + tx];  
		float logprob = __logf(labelp);
        labelLogProbs[tx] = logprob;
		//float err =  fmaxf(__logf(maxp) - logprob, 0);
		float w = __powf(-logprob + 1e-6, p_pow);//*.6/(.6 + err);

		probWeights[tx] = w;
        
        /*
         * Compute the probability of guessing the correct case if you take the most-probable label.
         * 
         * This is done like this:
         * 
         * - If the most probable label is not equal to the true label, then the probability is zero.
         * - Otherwise, the probability is 1 / (number of labels whose probability is equal to the maximum).
         * 
         * This is certainly overkill -- in practice, it's just about impossible for two labels to get assigned
         * maximum probability. But it's a safety measure to prevent over-estimating your accuracy.
         * Though it could never happen in reality. Well it could. But it wouldn't. Cool?
         */
        if (labelp != maxp) {
            correctProbs[tx] = 0;
        } else {
            int numMax = 0;
            for (int i = 0; i < numOut; i++) {
                numMax += probs[i * numCases + tx] == maxp;
            }
            correctProbs[tx] = 1.0f / float(numMax);
        }
    }
}

/*
 * E = -log(y_t)
 * y_l:     (numOut, numCases)
 * labels:  (1, numCases)
 * 
 * dE_dy_l: (numOut, numCases)
 */
template <bool add>
__global__ void kLogregCostGrad(float* y_l, float* labels, float* dE_dy_l, const int numCases,
                                 const int numOut, const float gradCoeff) {
    const int tx = blockIdx.x * LOGREG_GRAD_THREADS_X + threadIdx.x;
    const int ty = blockIdx.y * LOGREG_GRAD_THREADS_Y + threadIdx.y;
    const int tidx = ty * numCases + tx;
    
    if (ty < numOut && tx < numCases) {
        const int label = int(labels[tx]);
        float v = gradCoeff * (label == ty);
        v = __fdividef(v, y_l[tidx]);
        if (add) {
            dE_dy_l[tidx] += v;
        } else {
            dE_dy_l[tidx] = v;
        }
    }
}

/*
 * E = -log(y_t)
 * y_l:     (numOut, numCases)
 * labels:  (1, numCases)
 * 
 * dE_dy_l: (numOut, numCases)
 */
template <bool add>
__global__ void kRLogCostGrad(float* y_l, float* labels, float* dE_dy_l, float* weights, const int numCases,
                                 const int numOut, const float gradCoeff) {
    const int tx = blockIdx.x * LOGREG_GRAD_THREADS_X + threadIdx.x;
    const int ty = blockIdx.y * LOGREG_GRAD_THREADS_Y + threadIdx.y;
    const int tidx = ty * numCases + tx;
    
    if (ty < numOut && tx < numCases) {
        const int label = int(labels[tx]);
		const float w = weights[tx];
        float v = w*gradCoeff * (label == ty);
        v = __fdividef(v, y_l[tidx]);
        if (add) {
            dE_dy_l[tidx] += v;
        } else {
            dE_dy_l[tidx] = v;
        }
    }
}

/*
 * dE_dy_l: (numOut, numCases)
 * y_l:     (numOut, numCases)
 * 
 * dE_dx_l: (numOut, numCases)
 */
template <bool add>
__global__ void kSoftmaxGrad(float* dE_dy_l, float* y_l, float* dE_dx_l, const int numCases, const int numOut) {
    const int tx = blockIdx.x * LOGREG_GRAD_THREADS_X + threadIdx.x;
    const int ty = blockIdx.y * LOGREG_GRAD_THREADS_Y + threadIdx.y;
    const int tidx = ty * numCases + tx;
    
    if (ty < numOut && tx < numCases) {
        float v = 0;
        for (int j = 0; j < numOut; j++) {
            v += dE_dy_l[j * numCases + tx] * ((j == ty) - y_l[j * numCases + tx]);
        }
        v *= y_l[tidx];
        
        if (add) {
            dE_dx_l[tidx] += v;
        } else {
            dE_dx_l[tidx] = v;
        }
    }
}
__device__ inline float Psvm(float a, float invCp1, float C2) {
	return (a<0)*a + (a>C2)*invCp1*(a-C2);
};

__device__ inline float Gradsvm(float a, float C1, float C2) {
	return C1*fmax(a, 0) + C2*(a > 0);
};

__device__ inline float GradPsvm(float a, float invCp1z, float Cz, float C1, float C2) {
	return (a>Cz)*(C2 + C1*invCp1z*(a-Cz));
};

__global__ void kL2SVM_G(float* racts, float* acts, float* labels, float* sumZ2, float* G, const int numCases,
                                 const int numOut, const float C1, const float C2, const float eps_w, const float eps_b) {
    const int tx = blockIdx.x * LOGREG_GRAD_THREADS_X + threadIdx.x;
    const int ty = blockIdx.y * LOGREG_GRAD_THREADS_Y + threadIdx.y;
    const int tidx = ty * numCases + tx;
	
//eps = 1/lambda
   
    if (ty < numOut && tx < numCases) {
        const int label = int(labels[tx]);
		float t = (label == ty)?1:-1;
		float val = (1 - t*(racts[tidx]+acts[tidx]));

		const float ZL = sumZ2[tx]*eps_w + eps_b;

		const float invCp1z = 1.f/(1 + C1*ZL);
		const float Cz = C2*ZL;

		G[tidx] = t*GradPsvm(val, invCp1z, Cz, C1, C2);
    }

}

__global__ void kL2SVM_U(float* acts, float* labels, float* actU, const int numCases,
                                 const int numOut, const float C1eps, const float C2eps) {
    const int tx = blockIdx.x * LOGREG_GRAD_THREADS_X + threadIdx.x;
    const int ty = blockIdx.y * LOGREG_GRAD_THREADS_Y + threadIdx.y;
    const int tidx = ty * numCases + tx;
	
//eps = 1/lambda
   
    if (ty < numOut && tx < numCases) {
        const int label = int(labels[tx]);
		float t = (label == ty)?1:-1;
		float val = (1 - t*acts[tidx]);

		const float invCp1 = 1.f/(1 + C1eps);

		actU[tidx] = Psvm(val, invCp1, C2eps);
    }

}


template <bool add>
__global__ void kL2SVMGrad(float* y_l, float* labels, float* dE_dx_l, const int numCases,
                                 const int numOut, const float gradCoeff) {
    const int tx = blockIdx.x * LOGREG_GRAD_THREADS_X + threadIdx.x;
    const int ty = blockIdx.y * LOGREG_GRAD_THREADS_Y + threadIdx.y;
    const int tidx = ty * numCases + tx;
    
    if (ty < numOut && tx < numCases) {
        const int label = int(labels[tx]);
		float t = (label == ty)?1:-1;
		//y_l = w*act_prev
        //float v = gradCoeff*t*(1 - t*y_l[tidx] > 0); //-grad, because we are adding it and minimize
		float act = 1 - t*y_l[tidx];
		float max_val = fmaxf(act, 0) + .3*(act > 0);

		float v = gradCoeff*t*max_val; //-grad, because we are adding it and minimize
        if (add) {
            dE_dx_l[tidx] += v;
        } else {
            dE_dx_l[tidx] = v;
        }
    }
}

/*
 * E = -log(y_t)
 * y_l:     (numOut, numCases)
 * labels:  (1, numCases)
 * 
 * dE_dx_l: (numOut, numCases)
 */
template <bool add>
__global__ void kLogregSoftmaxGrad(float* y_l, float* labels, float* dE_dx_l, const int numCases,
                                 const int numOut, const float gradCoeff) {
    const int tx = blockIdx.x * LOGREG_GRAD_THREADS_X + threadIdx.x;
    const int ty = blockIdx.y * LOGREG_GRAD_THREADS_Y + threadIdx.y;
    const int tidx = ty * numCases + tx;
    
    if (ty < numOut && tx < numCases) {
        const int label = int(labels[tx]);
        float v = gradCoeff * ((label == ty) - y_l[tidx]);
        if (add) {
            dE_dx_l[tidx] += v;
        } else {
            dE_dx_l[tidx] = v;
        }
    }
}

template <bool add>
__global__ void kRLogSoftmaxGrad(float* y_l, float* labels, float* dE_dx_l, float* probWeights, const int numCases,
                                 const int numOut, const float gradCoeff) {
    const int tx = blockIdx.x * LOGREG_GRAD_THREADS_X + threadIdx.x;
    const int ty = blockIdx.y * LOGREG_GRAD_THREADS_Y + threadIdx.y;
    const int tidx = ty * numCases + tx;
    
    if (ty < numOut && tx < numCases) {
        const int label = int(labels[tx]);

		float p =  y_l[tidx];
		float w = probWeights[tx];

        float v = gradCoeff * ((label == ty) - p)*w;
        if (add) {
            dE_dx_l[tidx] += v;
        } else {
            dE_dx_l[tidx] = v;
        }
    }
}

template <int B_X, bool add>
__global__ void kEltwiseMaxGrad(float* actGrad, float* input, float* output, float* target,
                                const int numElements) {
    for (int i = B_X * blockIdx.x + threadIdx.x; i < numElements; i += B_X * gridDim.x) {
        if (add) {
            target[i] += actGrad[i] * (output[i] == input[i]);
        } else {
            target[i] = actGrad[i] * (output[i] == input[i]);
        }
    }
}

template <int B_X, int B_Y>
__global__ void kEltwiseFuncParamGrad(float* actGrad,
								float* input0, float* input1, float* input2,
								float* target0, float* target1, float* target2, float* target3, float* target4,
							    float param0, float param1, float param2, float param3, float param4,
								const uint imgPixels, const uint numCases,
								const uint stride, const int strideTag) {
    const uint idxX = blockIdx.x * B_X + threadIdx.x;
    const uint idxY = blockIdx.y * B_Y + threadIdx.y;

	int tagOffset = (threadIdx.x + blockIdx.x*blockDim.x) +  (threadIdx.y + blockIdx.y*blockDim.y)*strideTag;

	float sum0 = 0;
	float sum1 = 0;
	float sum2 = 0;
	float sum3 = 0;
	float sum4 = 0;
#pragma unroll
    for (uint y = idxY; y < imgPixels; y += gridDim.y * B_Y) {
#pragma unroll
        for (uint x = idxX; x < numCases; x += gridDim.x * B_X) {
			int offset = y * stride + x;
			float in0 = input0[offset];
			float in1 = input1[offset];
			float in2 = input2[offset];
			float grad_next = actGrad[offset];

			float fm0 = fmaxf(in0, 0);
			float fm1 = fmaxf(in1, 0);
			float fm2 = fmaxf(in2, 0);

			sum0 += grad_next*in1;
			sum1 += grad_next*in2;
			sum2 += grad_next*fm2;	
			sum3 += grad_next*fm0;
			sum4 += grad_next*fm1;

		//target0[offset] = grad_next*in1;
		//target1[offset] = grad_next*in2;
		//target2[offset] = grad_next*fm2;
		//target3[offset] = grad_next*fm0;
		//target4[offset] = grad_next*fm1;

            //float val = param0*in1 + param1*in2 + param2*fm2 + param3*fm0 + param4*fm1 + in0;
		}

		target0[tagOffset] = sum0;
		target1[tagOffset] = sum1;
		target2[tagOffset] = sum2;
		target3[tagOffset] = sum3;
		target4[tagOffset] = sum4;

   }
}

template <int B_X, int B_Y>
__global__ void kEltwiseFuncAct (const float* input0, const float* input1, const float* input2, float* const target,
							 const float param0, const float param1, const float param2, const float param3, const float param4,
							const uint imgPixels, const uint numCases,
                             const uint stride) {
    const uint idxX = blockIdx.x * B_X + threadIdx.x;
    const uint idxY = blockIdx.y * B_Y + threadIdx.y;

    for (uint y = idxY; y < imgPixels; y += gridDim.y * B_Y) {
        for (uint x = idxX; x < numCases; x += gridDim.x * B_X) {
			int offset = y * stride + x;

			float in0 = input0[offset];
			float in1 = input1[offset];
			float in2 = input2[offset];
			float fm0 = fmaxf(in0, 0);
			float fm1 = fmaxf(in1, 0);
			float fm2 = fmaxf(in2, 0);

            float val = param0*in1 + param1*in2 + param2*fm2 + param3*fm0 + param4*fm1 + in0;

            target[offset] = val;

        }
    }
}

template <int B_X, int B_Y>
__global__ void kEltwiseFuncGrad(float* actGrad,
								float* input0, float* input1, float* input2,
								float* target0, float* target1, float* target2,
								const float param0, const float param1, const float param2, const float param3, const float param4,
								const uint imgPixels, const uint numCases,
								const uint stride) {

    const uint idxX = blockIdx.x * B_X + threadIdx.x;
    const uint idxY = blockIdx.y * B_Y + threadIdx.y;

    for (uint y = idxY; y < imgPixels; y += gridDim.y * B_Y) {
        for (uint x = idxX; x < numCases; x += gridDim.x * B_X) {

			int offset = y * stride + x;

			float in0 = input0[offset];
			float in1 = input1[offset];
			float in2 = input2[offset];
			float grad_next = actGrad[offset];

			float val0 = 1 + param3*(in0 > 0);
			float val1 = param0 + param4*(in1 > 0);
			float val2 = param1 + param2*(in2 > 0);

			target0[offset] = val0*grad_next;
			target1[offset] = val1*grad_next;
			target2[offset] = val2*grad_next;

            //float val = param0*in1 + param1*in2 + param2*fm2 + param3*fm0 + param4*fm1 + in0;

		}
   }
}

void computeEltwiseMaxGrad(NVMatrix& actGrad, NVMatrix& input, NVMatrix& output, NVMatrix& target, bool add) {
    assert(actGrad.isContiguous());
    assert(output.isContiguous());
    assert(input.isContiguous());
    assert(actGrad.isSameDims(input));
    assert(actGrad.isSameDims(output));
  
    dim3 blocks(DIVUP(actGrad.getNumElements(), 128));
    dim3 threads(128);
    if (add) {
        assert(actGrad.isSameDims(target));
        cudaFuncSetCacheConfig(kEltwiseMaxGrad<128, true>, cudaFuncCachePreferL1);
        kEltwiseMaxGrad<128, true><<<blocks, threads>>>(actGrad.getDevData(), input.getDevData(), output.getDevData(), target.getDevData(), actGrad.getNumElements());
    } else {
        target.resize(actGrad);
        cudaFuncSetCacheConfig(kEltwiseMaxGrad<128, false>, cudaFuncCachePreferL1);
        kEltwiseMaxGrad<128, false><<<blocks, threads>>>(actGrad.getDevData(), input.getDevData(), output.getDevData(), target.getDevData(), actGrad.getNumElements());
    }
    
    cutilCheckMsg("computeEltwiseMaxGrad: Kernel execution failed");
}

void computeEltwiseFuncParamGrad(NVMatrix& actGrad, NVMatrix& input0, NVMatrix& input1,  NVMatrix& input2,
								 NVMatrix& target0, NVMatrix& target1, NVMatrix& target2, NVMatrix& target3, NVMatrix& target4,
								 float param0, float param1, float param2, float param3, float param4)
{
        int height = input0.getFollowingDim(), width = input0.getLeadingDim();

        dim3 blocks(std::min(NUM_BLOCKS_MAX, DIVUP(width, ELTWISE_THREADS_X)),
                    std::min(NUM_BLOCKS_MAX, DIVUP(height, ELTWISE_THREADS_Y)));
        dim3 threads(ELTWISE_THREADS_X, ELTWISE_THREADS_Y);

		int sizeX = blocks.x*threads.x;
		int sizeY = blocks.y*threads.y;

        if (target0.getNumRows() != sizeX || target0.getNumCols() !=  sizeY) {
            target0.resize(sizeX, sizeY);
        }

		////debug
  //      if (!target0.isSameDims(input0)) {
  //          target0.resize(input0);
  //      }//shortening is not working

        if (!target1.isSameDims(target0)) {
            target1.resize(target0);
        }

        if (!target2.isSameDims(target0)) {
            target2.resize(target0);
        }

        if (!target3.isSameDims(target0)) {
            target3.resize(target0);
        }

        if (!target4.isSameDims(target0)) {
            target4.resize(target0);
        }

		cudaFuncSetCacheConfig(kEltwiseFuncParamGrad<ELTWISE_THREADS_X, ELTWISE_THREADS_Y>, cudaFuncCachePreferL1);

		kEltwiseFuncParamGrad<ELTWISE_THREADS_X, ELTWISE_THREADS_Y><<<blocks, threads>>>(actGrad.getDevData(), 
			input0.getDevData(), input1.getDevData(), input2.getDevData(),
			target0.getDevData(), target1.getDevData(), target2.getDevData(), target3.getDevData(), target4.getDevData(),
			param0, param1, param2, param3, param4,
			height, width, input0.getStride(), sizeX);

		cutilCheckMsg("kEltwiseFuncParamGrad: Kernel execution failed");
};

void computeEltwiseFuncAct(NVMatrix& input0, NVMatrix& input1,  NVMatrix& input2,
								 NVMatrix& target, float param0, float param1, float param2, float param3, float param4)
{

        if (!target.isSameDims(input0)) {
            target.resize(input0);
        }

        int height = input0.getFollowingDim(), width = input0.getLeadingDim();

        dim3 blocks(std::min(NUM_BLOCKS_MAX, DIVUP(width, ELTWISE_THREADS_X)),
                    std::min(NUM_BLOCKS_MAX, DIVUP(height, ELTWISE_THREADS_Y)));
        dim3 threads(ELTWISE_THREADS_X, ELTWISE_THREADS_Y);

		cudaFuncSetCacheConfig(kEltwiseFuncAct<ELTWISE_THREADS_X, ELTWISE_THREADS_Y>, cudaFuncCachePreferL1);
		kEltwiseFuncAct<ELTWISE_THREADS_X, ELTWISE_THREADS_Y><<<blocks, threads>>>(input0.getDevData(), input1.getDevData(), input2.getDevData(),
			target.getDevData(), param0, param1, param2, param3, param4, 
			height, width, input0.getStride());

		cutilCheckMsg("computeEltwiseFuncAct: Kernel execution failed");

}

void computeEltwiseFuncGrad(NVMatrix& actGrad, NVMatrix& input0, NVMatrix& input1,  NVMatrix& input2,
								 NVMatrix& target0, NVMatrix& target1, NVMatrix& target2,
								 float param0, float param1, float param2, float param3, float param4)
{

        if (!target0.isSameDims(input0)) {
            target0.resize(input0);
        }

        if (!target1.isSameDims(input1)) {
            target1.resize(input1);
        }

        if (!target2.isSameDims(input2)) {
            target2.resize(input2);
        }

        int height = input0.getFollowingDim(), width = input0.getLeadingDim();

        dim3 blocks(std::min(NUM_BLOCKS_MAX, DIVUP(width, ELTWISE_THREADS_X)),
                    std::min(NUM_BLOCKS_MAX, DIVUP(height, ELTWISE_THREADS_Y)));
        dim3 threads(ELTWISE_THREADS_X, ELTWISE_THREADS_Y);

		cudaFuncSetCacheConfig(kEltwiseFuncGrad<ELTWISE_THREADS_X, ELTWISE_THREADS_Y>, cudaFuncCachePreferL1);

		kEltwiseFuncGrad<ELTWISE_THREADS_X, ELTWISE_THREADS_Y><<<blocks, threads>>>(actGrad.getDevData(), 
			input0.getDevData(), input1.getDevData(), input2.getDevData(),
			target0.getDevData(), target1.getDevData(), target2.getDevData(),
			param0, param1, param2, param3, param4,
			height, width, input0.getStride());

		cutilCheckMsg("computeEltwiseFuncAct: Kernel execution failed");
};

void computeL2SVMCost(NVMatrix& labels, NVMatrix& act_prev, NVMatrix& act_out, NVMatrix& correctPreds_out)
{
    int numCases = act_prev.getNumCols(); 
    int numOut = act_prev.getNumRows(); 

    assert(labels.getNumElements() == numCases);
    assert(!labels.isTrans());
    assert(!act_prev.isTrans());
    assert(labels.isContiguous());
    assert(act_prev.isContiguous());
    
    NVMatrix& maxActs = act_prev.max(0);
    
    act_out.resize(1, numCases);
    correctPreds_out.resize(1, numCases);
    dim3 threads(LOGREG_ERR_THREADS_X, 1);
    dim3 blocks(DIVUP(numCases, LOGREG_ERR_THREADS_X), 1);
    cudaFuncSetCacheConfig(kL2SVMCost, cudaFuncCachePreferL1);

    kL2SVMCost<<<blocks, threads>>>(act_prev.getDevData(), labels.getDevData(), maxActs.getDevData(),
                                    act_out.getDevData(), correctPreds_out.getDevData(),
                                    numCases, numOut);
    cutilCheckMsg("computeL2SVMCost: Kernel execution failed");

    delete &maxActs;
};

/*
 * E = -log(y_t)
 * probs:           (numOut, numCases)
 * labels:          (1, numCases)
 * maxProbs:        (1, numCases)
 * labelLogProbs:   (1, numCases)   (*out)
 * correctProbs:    (1, numCases)   (*out)
 * 
 * target:          (1, numCases)
 */
void computeLogregCost(NVMatrix& labels, NVMatrix& probs, NVMatrix& labelLogProbs_out, NVMatrix& correctProbs_out) {
    int numCases = probs.getNumCols(); 
    int numOut = probs.getNumRows(); 

    assert(labels.getNumElements() == numCases);
    assert(!labels.isTrans());
    assert(!probs.isTrans());
    assert(labels.isContiguous());
    assert(probs.isContiguous());
    
    NVMatrix& maxProbs = probs.max(0);
    
    labelLogProbs_out.resize(1, numCases);
    correctProbs_out.resize(1, numCases);
    dim3 threads(LOGREG_ERR_THREADS_X, 1);
    dim3 blocks(DIVUP(numCases, LOGREG_ERR_THREADS_X), 1);
    cudaFuncSetCacheConfig(kLogregCost, cudaFuncCachePreferL1);
    kLogregCost<<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), maxProbs.getDevData(),
                                     labelLogProbs_out.getDevData(), correctProbs_out.getDevData(),
                                     numCases, numOut);
    cutilCheckMsg("computeLogregCost: Kernel execution failed");
//    cudaThreadSynchronize();
    delete &maxProbs;
}

void computeLogregGrad(NVMatrix& labels, NVMatrix& probs, NVMatrix& target, bool add, float coeff) {
    int numCases = probs.getLeadingDim(); 
    int numOut = probs.getFollowingDim(); 
    assert(labels.getNumElements() == numCases);
    assert(probs.isContiguous());
    assert(target.isContiguous());
    assert(labels.isContiguous());
    assert(!labels.isTrans());
    assert(!probs.isTrans());
    
    dim3 threads(LOGREG_GRAD_THREADS_X, LOGREG_GRAD_THREADS_Y);
    dim3 blocks(DIVUP(numCases, LOGREG_GRAD_THREADS_X), DIVUP(numOut, LOGREG_GRAD_THREADS_Y));
    if (!add) {
        target.resize(probs);
        kLogregCostGrad<false><<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), target.getDevData(),
                                                     numCases, numOut, coeff);
    } else {
        kLogregCostGrad<true><<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), target.getDevData(),
                                                     numCases, numOut, coeff);
    }

    cutilCheckMsg("computeLogregGrad: Kernel execution failed");
}

void computeRLogCost(NVMatrix& labels, NVMatrix& probs,
					 NVMatrix& labelLogProbs_out, NVMatrix& correctProbs_out, NVMatrix& probWeights_out,
					 float p_pow) {
    int numCases = probs.getNumCols(); 
    int numOut = probs.getNumRows(); 

    assert(labels.getNumElements() == numCases);
    assert(!labels.isTrans());
    assert(!probs.isTrans());
    assert(labels.isContiguous());
    assert(probs.isContiguous());
    
    NVMatrix& maxProbs = probs.max(0);
    
    labelLogProbs_out.resize(1, numCases);
    correctProbs_out.resize(1, numCases);
    dim3 threads(LOGREG_ERR_THREADS_X, 1);
    dim3 blocks(DIVUP(numCases, LOGREG_ERR_THREADS_X), 1);
    cudaFuncSetCacheConfig(kRLogCost, cudaFuncCachePreferL1);
    kRLogCost<<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), maxProbs.getDevData(),
                                     labelLogProbs_out.getDevData(), correctProbs_out.getDevData(),
									 probWeights_out.getDevData(), p_pow, numCases, numOut);
    cutilCheckMsg("computeRLogCost: Kernel execution failed");

    delete &maxProbs;
}

void computeRLogGrad(NVMatrix& labels, NVMatrix& probs, NVMatrix& target, NVMatrix& probWeights, bool add, float coeff) {
    int numCases = probs.getLeadingDim(); 
    int numOut = probs.getFollowingDim(); 
    assert(labels.getNumElements() == numCases);
    assert(probs.isContiguous());
    assert(target.isContiguous());
    assert(labels.isContiguous());
    assert(!labels.isTrans());
    assert(!probs.isTrans());
    
    dim3 threads(LOGREG_GRAD_THREADS_X, LOGREG_GRAD_THREADS_Y);
    dim3 blocks(DIVUP(numCases, LOGREG_GRAD_THREADS_X), DIVUP(numOut, LOGREG_GRAD_THREADS_Y));
    if (!add) {
        target.resize(probs);
        kRLogCostGrad<false><<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), target.getDevData(), probWeights.getDevData(),
                                                     numCases, numOut, coeff);
    } else {
        kRLogCostGrad<true><<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), target.getDevData(), probWeights.getDevData(),
                                                     numCases, numOut, coeff);
    }

    cutilCheckMsg("computeLogregGrad: Kernel execution failed");
}

void computeL2SVMGrad(NVMatrix& labels, NVMatrix& acts, NVMatrix& target, bool add, float coeff)
{
    int numCases = acts.getLeadingDim(); 
    int numOut = acts.getFollowingDim(); 
    assert(labels.getNumElements() == numCases);
    assert(acts.isContiguous());
    assert(target.isContiguous());
    assert(labels.isContiguous());
    assert(acts.isTrans());
    
    dim3 threads(LOGREG_GRAD_THREADS_X, LOGREG_GRAD_THREADS_Y);
    dim3 blocks(DIVUP(numCases, LOGREG_GRAD_THREADS_X), DIVUP(numOut, LOGREG_GRAD_THREADS_Y));
    if (!add) {
        target.resize(acts);
        kL2SVMGrad<false><<<blocks, threads>>>(acts.getDevData(), labels.getDevData(), target.getDevData(),
                                                     numCases, numOut, coeff);
    } else {
        kL2SVMGrad<true><<<blocks, threads>>>(acts.getDevData(), labels.getDevData(), target.getDevData(),
                                                     numCases, numOut, coeff);
    }

};

void computeSoftmaxGrad(NVMatrix& acts, NVMatrix& actsGrad, NVMatrix& target, bool add) {
    int numCases = acts.getLeadingDim();
    int numOut = acts.getFollowingDim();

    assert(acts.isSameDims(actsGrad));
    assert(acts.isContiguous());
    assert(actsGrad.isContiguous());
    assert(target.isContiguous());
    assert(acts.isTrans());
    assert(actsGrad.isTrans());

    dim3 threads(LOGREG_GRAD_THREADS_X, LOGREG_GRAD_THREADS_Y);
    dim3 blocks(DIVUP(numCases, LOGREG_GRAD_THREADS_X), DIVUP(numOut, LOGREG_GRAD_THREADS_Y));
    if (!add) {
        target.resize(acts);
        kSoftmaxGrad<false><<<blocks, threads>>>(actsGrad.getDevData(), acts.getDevData(), target.getDevData(), numCases, numOut);
    } else {
        kSoftmaxGrad<true><<<blocks, threads>>>(actsGrad.getDevData(), acts.getDevData(), target.getDevData(), numCases, numOut);
    }
    cutilCheckMsg("computeSoftmaxGrad: Kernel execution failed");
}

void computeLogregSoftmaxGrad(NVMatrix& labels, NVMatrix& probs, NVMatrix& target, bool add, float coeff) {
    int numCases = probs.getLeadingDim(); 
    int numOut = probs.getFollowingDim(); 
    assert(labels.getNumElements() == numCases);
    assert(probs.isContiguous());
    assert(target.isContiguous());
    assert(labels.isContiguous());
    assert(probs.isTrans());
    
    dim3 threads(LOGREG_GRAD_THREADS_X, LOGREG_GRAD_THREADS_Y);
    dim3 blocks(DIVUP(numCases, LOGREG_GRAD_THREADS_X), DIVUP(numOut, LOGREG_GRAD_THREADS_Y));
    if (!add) {
        target.resize(probs);
        kLogregSoftmaxGrad<false><<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), target.getDevData(),
                                                     numCases, numOut, coeff);
    } else {
        kLogregSoftmaxGrad<true><<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), target.getDevData(),
                                                     numCases, numOut, coeff);
    }

    cutilCheckMsg("computeLogregSoftmaxGrad: Kernel execution failed");
}

void computeRLogSoftmaxGrad(NVMatrix& labels, NVMatrix& probs, NVMatrix& target, NVMatrix& probWeights, bool add, float coeff) {
    int numCases = probs.getLeadingDim(); 
    int numOut = probs.getFollowingDim(); 
    assert(labels.getNumElements() == numCases);
    assert(probs.isContiguous());
    assert(target.isContiguous());
    assert(labels.isContiguous());
    assert(probs.isTrans());

	if(!labels.isSameDims(probWeights)) {
		printf("computeRLogSoftmaxGrad - probWeights dimesions are wrong! \n");
		exit(EXIT_FAILURE);
	}
    
    dim3 threads(LOGREG_GRAD_THREADS_X, LOGREG_GRAD_THREADS_Y);
    dim3 blocks(DIVUP(numCases, LOGREG_GRAD_THREADS_X), DIVUP(numOut, LOGREG_GRAD_THREADS_Y));
    if (!add) {
        target.resize(probs);
        kRLogSoftmaxGrad<false><<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), target.getDevData(), probWeights.getDevData(),
                                                     numCases, numOut, coeff);
    } else {
        kRLogSoftmaxGrad<true><<<blocks, threads>>>(probs.getDevData(), labels.getDevData(), target.getDevData(), probWeights.getDevData(),
                                                     numCases, numOut, coeff);
    }

    cutilCheckMsg("computeRLogSoftmaxGrad: Kernel execution failed");
}