/* Copyright 2013 The Science and Technology Facilities Council (STFC)
 * Copyright 2013 NVIDIA (in collaboration with STFC)
 *
 * Authors:
 * Jonathan Hogg        STFC     jonathan.hogg@stfc.ac.uk
 * Jeremey Appleyard    NVIDIA
 *
 * This code has not yet been publically released under any licence.
 */

#include <stdio.h>
#include <stdlib.h>
#include "../cuda/cuda_check.h"
#include "cublas_v2.h"

//#define MIN(x,y) (((x)>(y))?(y):(x))
#define MAX(x,y) (((x)>(y))?(x):(y))

#include "dtrsv.h"

#define TRSM_TR_NBX 256
#define TRSM_TR_NBY 32
#define TRSM_TR_THREADSX 32
#define TRSM_TR_THREADSY 4
#define REDUCING_D_SOLVE_THREADS_PER_BLOCK 256
#define SCATTER_NB 256
#define GEMV_NX 32
#define GEMV_NY 32
#define GEMV_THREADSX 32
#define GEMV_THREADSY 4
#define ASSEMBLE_NB 128

namespace spral { namespace ssids {

/* Perform the assignment xdense(:) = xsparse( idx(:) ) */
template <int threadsx, int threadsy>
void __device__ gather(int n, const int *idx, const double *xsparse,
      double *xdense) {
   int tid = threadsx*threadIdx.y + threadIdx.x;
   for(int i=tid; i<n; i+=threadsx*threadsy)
      xdense[i] = xsparse[ idx[i] ];
}

/***********************************************************************/
/***********************************************************************/
/***********************************************************************/

struct gemv_transpose_lookup {
   int m; // number of rows of L (cols of L^T) for block
   int n; // number of cols of L (rows of L^T) for block
   const double *a;
   int lda; // leading dimension of a
   const int *rlist;
   int yoffset; // offset into y for answer
};

/* This subroutine performs a matrix-vector multiplication y = Ax where
 * x is a sparse vector indexed into by rlist.
 * The lookup[] array is indexed into by the block id and specifies which
 * part of the matrix we're working on.
 *
 * Requires max(maxm + maxn*threadsx) shared memory.
 * Requires threadsy to exactly divide maxn.
 */
template <int threadsx, int threadsy, int maxm, int maxn>
__launch_bounds__(threadsx*threadsy, 6)
void __global__ gemv_transpose_sps_rhs(struct gemv_transpose_lookup *lookup,
      double *x, double *y
      ) {

   // Reuse shmem for two different purposes
   double __shared__ shmem[maxn*threadsx];
   double *partSum = shmem;
   double *xlocal = shmem;

   double partSumReg[maxn / threadsy]; // Assumes neat division


   lookup += blockIdx.x;
   int m = lookup->m;
   int n = lookup->n;
   const double *a = lookup->a;
   const int *rlist = lookup->rlist;
   int lda = lookup->lda;
   y += lookup->yoffset;

   /* Read x(rlist(:)) into xlocal(:) */
   gather <threadsx,threadsy> (m, rlist, x, xlocal);
   __syncthreads();

   /* Perform matrix-vector multiply with answer y in register that
      is then stored in partSum for later reduction. */
   if(m==maxm) {
      double *xl = xlocal + threadIdx.x;
#pragma unroll
      for(int iLoop=0; iLoop<maxn/threadsy; iLoop++) { // row
         int i = iLoop * threadsy + threadIdx.y;
         partSumReg[iLoop] = 0;
         if (i < n) {
            const double *arow = a+i*lda+threadIdx.x;
            for(int j=0; j<maxm; j+=threadsx)
               partSumReg[iLoop] += xl[j] * arow[j];
         }
      }
   } else {
#pragma unroll
      for(int iLoop=0; iLoop<maxn/threadsy; iLoop++) { // row
         int i = iLoop * threadsy + threadIdx.y;
         partSumReg[iLoop] = 0;
         if (i < n) {
            const double *arow = a+i*lda;
            for(int j=threadIdx.x; j<m; j+=threadsx)
               partSumReg[iLoop] += xlocal[j] * arow[j];
         }
      }
   }

   __syncthreads(); // Wait till done with xlocal=shmem before using partSum
#pragma unroll
   for(int iLoop=0; iLoop<maxn/threadsy; iLoop++) { // row
      int i = iLoop * threadsy + threadIdx.y;
      if (i < n) {
         partSum[i*threadsx+threadIdx.x] = partSumReg[iLoop];
      }
   }

   __syncthreads();

   /* Reduce partSum across threads to get y contribution from this block */
   if(threadIdx.y==0) {
      for(int i=threadIdx.x; i<n; i+=threadsx) {
         double val = 0;
         /* The offset avoids large bank conflicts. */
         for(int j=threadIdx.x; j<threadsx+threadIdx.x; j++) {
            int j2 = (j >= threadsx ? j - threadsx : j);
            val += partSum[i*threadsx+j2];
         }
         y[i] = val;
      }
   }

}

/***********************************************************************/
/***********************************************************************/
/***********************************************************************/

struct reducing_d_solve_lookup {
   int first_idx; // Index of supernode for thread 0 of this block.
   int m; // Number of columns in upd to reduce.
   int n; // Number of rows THIS BLOCK is responisble for.
   int ldupd; // Leading dimension of upd.
   int updoffset; // Offset into upd for supernode.
   const double *d;
   const int *perm; // Offset into perm for supernode.
};

/* This subroutine performs two unrelated tasks and subtracts the result of the
 * first from the second.
 * Task 1: Sum along the rows of the m x n matrix upd. (This is reducing the
 *         result of a previous gemv operation).
 * Task 2: Peform the special matrix-vector multiplication D^-1 P x where
 *         D is a block diagonal matrix with 1x1 and 2x2 blocks, and
 *         P is a (partial) permutation matrix, given by the vector perm.
 * The result x_2-x_1 is returned replacing the first column of upd.
 */
template <int threadsx, bool DSOLVE>
void __global__ reducing_d_solve(struct reducing_d_solve_lookup *lookup,
      double *upd, const double *x
      ) {

   /* Read details from lookup */
   lookup += blockIdx.x;
   int idx = lookup->first_idx + threadIdx.x;
   int m = lookup->m;
   int n = lookup->n;
   int ldupd = lookup->ldupd;
   upd += lookup->updoffset;
   const double *d = lookup->d;
   const int *perm = lookup->perm;


   /* Don't do anything on threads past end of arrays */
   if(threadIdx.x>=m) return;

   /* Task 1: Sum upd and negate */
   double val = upd[idx];
   for(int j=1; j<n; j++)
      val += upd[j*ldupd+idx];
   val = -val;

   /* Task 2: D solve (note that D is actually stored as inverse already) */
   if(DSOLVE) {
      int rp = perm[idx];
      if(idx!=0 && d[2*idx-1] != 0) {
         /* second part of 2x2 */
         int rp2 = perm[idx-1];
         val += d[2*idx-1] * x[rp2] +
                d[2*idx]   * x[rp];
      } else if (d[2*idx+1] != 0) {
         /* first part of 2x2 */
         int rp2 = perm[idx+1];
         val += d[2*idx]   * x[rp] +
                d[2*idx+1] * x[rp2];
      } else {
         /* 1x1 */
         val += x[rp]*d[2*idx];
      }
   } else {
      int rp = perm[idx];
      val += x[rp];
   }

   /* Store result as first column of upd */
   upd[idx] = val;

}

/* This subroutine only performs the solve with D. For best performance, use
 * reducing_d_solve() instead.
 * Peform the special matrix-vector multiplication D^-1 P x where
 * D is a block diagonal matrix with 1x1 and 2x2 blocks, and
 * P is a (partial) permutation matrix, given by the vector perm.
 * The result is not returned in-place due to 2x2 pivots potentially
 * split between blocks.
 */
template <int threadsx>
void __global__ d_solve(struct reducing_d_solve_lookup *lookup,
      const double *x, double *y) {

   /* Read details from lookup */
   lookup += blockIdx.x;
   int idx = lookup->first_idx + threadIdx.x;
   int m = lookup->m;
   const double *d = lookup->d;
   const int *perm = lookup->perm;

   /* Don't do anything on threads past end of arrays */
   if(threadIdx.x>=m) return;

   /* D solve (note that D is actually stored as inverse already) */
   int rp = perm[idx];
   double val;
   if(idx!=0 && d[2*idx-1] != 0) {
      /* second part of 2x2 */
      int rp2 = perm[idx-1];
      val = d[2*idx-1] * x[rp2] +
            d[2*idx]   * x[rp];
   } else if (d[2*idx+1] != 0) {
      /* first part of 2x2 */
      int rp2 = perm[idx+1];
      val = d[2*idx]   * x[rp] +
            d[2*idx+1] * x[rp2];
   } else {
      /* 1x1 */
      val = x[rp]*d[2*idx];
   }

   /* Store result in y[] */
   y[rp] = val;
}

/***********************************************************************/
/***********************************************************************/
/***********************************************************************/

struct scatter_lookup {
   int n;
   int src_offset;
   const int *index;
   int dest_offset;
};

/* This subroutine performs the scatter operation dest( index(:) ) = src(:)
 */
void __global__ scatter(struct scatter_lookup *lookup, const double *src,
      double *dest
      ) {

   lookup += blockIdx.x;
   if(threadIdx.x >= lookup->n) return; // Skip on out of range threads
   src += lookup->src_offset;
   const int *index = lookup->index;
   dest += lookup->dest_offset;


   int idx = index[threadIdx.x];
   dest[idx] = src[threadIdx.x];

}

/***********************************************************************/
/***********************************************************************/
/***********************************************************************/

struct lookups_gpu_bwd {
   int ngemv;
   int nrds;
   int ntrsv;
   int nscatter;
   struct gemv_transpose_lookup *gemv;
   struct reducing_d_solve_lookup *rds;
   struct trsv_lookup *trsv;
   struct scatter_lookup *scatter;
};

/*
 * Perform y = Ax
 * Result y actually output as array with leading dimn m that must be summed
 * externally.
 */
template <int threadsx, int threadsy, int maxm, int maxn>
void __global__ simple_gemv(int m, int n, const double *a, int lda,
      const double *x, double *y) {
   a += blockIdx.x*maxm + (blockIdx.y*maxn)*lda;
   x += blockIdx.y*maxn;
   y += m*blockIdx.y + maxm*blockIdx.x;

   double __shared__ partSum[maxm*threadsy];

   m = MIN(maxm, m-blockIdx.x*maxm);
   n = MIN(maxn, n-blockIdx.y*maxn);

   double *ps = partSum + maxm*threadIdx.y;
   for(int j=threadIdx.x; j<m; j+=threadsx) {
      ps[j] = 0;
   }
   for(int i=threadIdx.y; i<n; i+=threadsy) {
      double xv = x[i];
      for(int j=threadIdx.x; j<m; j+=threadsx) {
         ps[j] += a[i*lda+j]*xv;
      }
   }

   __syncthreads();
   if(threadIdx.y==0) {
      for(int j=threadIdx.x; j<m; j+=threadsx) {
         double val = ps[j];
         for(int i=1; i<threadsy; i++) {
            val += ps[j+i*maxm];
         }
         y[j] = val;
      }
   }
}

struct gemv_notrans_lookup {
   int m;
   int n;
   const double *a;
   int lda;
   int x_offset;
   int y_offset;
};

template <int threadsx, int threadsy, int maxm, int maxn>
void __global__ simple_gemv_lookup(const double *x, double *y,
      struct gemv_notrans_lookup *lookup) {
   lookup += blockIdx.x;
   int m = lookup->m;
   int n = lookup->n;
   double const* a = lookup->a;
   int lda = lookup->lda;
   x += lookup->x_offset;
   y += lookup->y_offset;

   double __shared__ partSum[maxm*threadsy];

   double *ps = partSum + maxm*threadIdx.y;

   // Templated parameters for shortcut
   if (maxm <= threadsx) {
      ps[threadIdx.x] = 0;
   }
   else {
      for(int j=threadIdx.x; j<m; j+=threadsx) {
         ps[j] = 0;
      }
   }
   for(int i=threadIdx.y; i<n; i+=threadsy) {
      double xv = x[i];
      // Templated parameters for shortcut - this reads out of bounds so shouldn't be uncommented
      /*if (maxm <= threadsx) {
         ps[threadIdx.x] += a[i*lda+threadIdx.x]*xv;
      }
      else {*/
         for(int j=threadIdx.x; j<m; j+=threadsx) {
            ps[j] += a[i*lda+j]*xv;
         }
      //}
   }

   __syncthreads();
   if(threadIdx.y==0) {
      // Templated parameters for shortcut
      if (maxm <= threadsx) {
         if (threadIdx.x < m) {
            double val = ps[threadIdx.x];
            for(int i=1; i<threadsy; i++) {
               val += ps[threadIdx.x+i*maxm];
            }
            y[threadIdx.x] = val;
         }
      }
      else {
         for(int j=threadIdx.x; j<m; j+=threadsx) {
            double val = ps[j];
            for(int i=1; i<threadsy; i++) {
               val += ps[j+i*maxm];
            }
            y[j] = val;
         }
      }
   }
}

struct reduce_notrans_lookup {
   int m;
   int n;
   int src_offset;
   int ldsrc;
   int dest_idx;
   int dest_offset;
};

void __global__ gemv_reduce_lookup(const double *src, double **dest, int numLookups, struct reduce_notrans_lookup *lookup) {
   int offset = blockIdx.x * blockDim.y + threadIdx.y;
   if (offset >= numLookups) return;

   lookup += offset;
   int m = lookup->m;
   if(threadIdx.x>=m) return;
   int n = lookup->n;
   src += lookup->src_offset + threadIdx.x;
   int ldsrc = lookup->ldsrc;
   double *d = dest[lookup->dest_idx] + lookup->dest_offset;

   double val = 0;
   for(int i=0; i<n; i++)
      val += src[i*ldsrc];
   d[threadIdx.x] -= val;
}

void __global__ gemv_reduce(int m, int n, const double *src, double **dest) {
   int idx = blockIdx.x*blockDim.x + threadIdx.x;
   if(idx>=m) return;
   src += idx;
   double val = 0;
   for(int i=0; i<n; i++)
      val += src[i*m];
   (*dest)[idx] -= val;
}

/* Each thread looks after exactly one entry of x only */
void __global__ assemble(int m, int nelim, int const* list, double *xlocal,
      double **xstack, const double *x, int nchild, int const* clen,
      int * const* clists, double * const* cvalues) {

   /* Calculate entry, return if out of range */
   int idx = blockIdx.x*blockDim.x + threadIdx.x;
   if(idx>=m) return;
   int row = list[idx];

   /* Accumulate contribution */
   double val=0;
   for(int child=0; child<nchild; child++) {
      const int *clist = clists[child];
      const double *cval = cvalues[child];
      int i;
      /* Note: If we want to optimize this, try fixing the upper bound, but
         beware: delays can cause the child rlist to be out of order! */
      for(i=0; i<clen[child]; i++) {
         if(clist[i] == row) {
            val += cval[i];
            break;
         }
      }
   }

   /* Add to x or xstack as appropriate */
   if(idx<nelim)  xlocal[idx] = x[row] + val;
   else           (*xstack)[idx-nelim] = val;
}

struct assemble_lookup {
   int m;
   int xend;
   int const* list;
   int x_offset;
   int contrib_idx;
   int contrib_offset;
   int nchild;
   int const* clen;
   int * const* clists;
   int cvalues_offset;
   int first; // First index of node. Used to shortcut searching
};

/* Each thread looks after exactly one entry of x only */
void __global__ assemble_lvl(double *xlocal,
      double **xstack, const double *x, double * const* cvalues,
      struct assemble_lookup *lookup) {

   lookup += blockIdx.x;
   if(threadIdx.x>=lookup->m) return;
   int xend = lookup->xend;
   double *contrib =
      (threadIdx.x>=xend) ?
         xstack[lookup->contrib_idx]+lookup->contrib_offset :
         NULL;
   xlocal += lookup->x_offset;
   int nchild = lookup->nchild;
   int const* clen = lookup->clen;
   int * const* clists = lookup->clists;
   cvalues += lookup->cvalues_offset;

   int row = lookup->list[threadIdx.x];

   /* Accumulate contribution */
   double val=0;
   for(int child=0; child<nchild; child++) {
      const int *clist = clists[child];
      const double *cval = cvalues[child];
      /* Note: If we want to optimize this, try fixing the upper bound, but
         beware: delays can cause the child rlist to be out of order! */
      for(int i=0; i<clen[child]; i++) {
         if(clist[i] == row) {
            val += cval[i];
         }
      }
   }

   /* Add to x or xstack as appropriate */
   if(threadIdx.x<xend) xlocal[threadIdx.x] = x[row] + val;
   else                 contrib[threadIdx.x] = val;
}

struct lookups_gpu_fwd {
   int nassemble;
   int ntrsv;
   int ngemv;
   int nreduce;
   int nscatter;
   struct assemble_lookup *assemble;
   struct trsv_lookup *trsv;
   struct gemv_notrans_lookup *gemv;
   struct reduce_notrans_lookup *reduce;
   struct scatter_lookup *scatter;
};

} } // end namespace spral::ssids

/*******************************************************************************
 * Following routines are exported with C binding so can be called from Fortran
 ******************************************************************************/

using namespace spral::ssids;

extern "C" {

void spral_ssids_run_fwd_solve_kernels(bool posdef,
      struct lookups_gpu_fwd const* gpu, double *xlocal_gpu,
      double **xstack_gpu, double *x_gpu, double ** cvalues_gpu,
      double *work_gpu, int nsync, int *sync, const cudaStream_t *stream) {

   if(nsync>0) trsv_init <<<nsync, 1, 0, *stream>>> (sync);
   assemble_lvl
      <<<gpu->nassemble, ASSEMBLE_NB, 0, *stream>>>
      (xlocal_gpu, xstack_gpu, x_gpu, cvalues_gpu, gpu->assemble);
   CudaCheckError();
   if(gpu->ntrsv>0) {
      if(posdef) {
         trsv_ln_exec
            <double,TRSV_NB_TASK,THREADSX_TASK,THREADSY_TASK,false>
            <<<gpu->ntrsv, dim3(THREADSX_TASK,THREADSY_TASK), 0, *stream>>>
            (xlocal_gpu, sync, gpu->trsv);
      } else {
         trsv_ln_exec
            <double,TRSV_NB_TASK,THREADSX_TASK,THREADSY_TASK,true>
            <<<gpu->ntrsv, dim3(THREADSX_TASK,THREADSY_TASK), 0, *stream>>>
            (xlocal_gpu, sync, gpu->trsv);
      }
      CudaCheckError();
   }
   if(gpu->ngemv>0) {
      simple_gemv_lookup
         <GEMV_THREADSX, GEMV_THREADSY, GEMV_NX, GEMV_NY>
         <<<gpu->ngemv, dim3(GEMV_THREADSX,GEMV_THREADSY), 0, *stream>>>
         (xlocal_gpu, work_gpu, gpu->gemv);
      CudaCheckError();
   }
   if(gpu->nreduce>0) {
      gemv_reduce_lookup
         <<<dim3((gpu->nreduce + 4 - 1) / 4), dim3(GEMV_NX, 4), 0, *stream>>>
         (work_gpu, cvalues_gpu, gpu->nreduce, gpu->reduce);
      CudaCheckError();
   }
   scatter
      <<<gpu->nscatter, SCATTER_NB, 0, *stream>>>
      (gpu->scatter, xlocal_gpu, x_gpu);
   CudaCheckError();
}

void spral_ssids_run_d_solve_kernel(double *x_gpu, double *y_gpu,
      struct lookups_gpu_bwd *gpu, const cudaStream_t *stream) {

   if(gpu->nrds>0) {
      d_solve
         <REDUCING_D_SOLVE_THREADS_PER_BLOCK>
         <<<gpu->nrds, REDUCING_D_SOLVE_THREADS_PER_BLOCK, 0, *stream>>>
         (gpu->rds, x_gpu, y_gpu);
      CudaCheckError();
   }
}

void spral_ssids_run_bwd_solve_kernels(bool dsolve, bool unit_diagonal,
      double *x_gpu, double *work_gpu, int nsync, int *sync_gpu,
      struct lookups_gpu_bwd *gpu, const cudaStream_t *stream) {

   /* === Kernel Launches === */
   if(nsync>0) trsv_init <<<nsync, 1, 0, *stream>>> (sync_gpu);
   if(gpu->ngemv>0) {
      gemv_transpose_sps_rhs
         <TRSM_TR_THREADSX, TRSM_TR_THREADSY, TRSM_TR_NBX, TRSM_TR_NBY>
         <<<gpu->ngemv, dim3(TRSM_TR_THREADSX,TRSM_TR_THREADSY), 0, *stream>>>
         (gpu->gemv, x_gpu, work_gpu);
      CudaCheckError();
   }

   if(gpu->nrds>0) {
      if(dsolve) {
         reducing_d_solve
            <REDUCING_D_SOLVE_THREADS_PER_BLOCK, true>
            <<<gpu->nrds, REDUCING_D_SOLVE_THREADS_PER_BLOCK, 0, *stream>>>
            (gpu->rds, work_gpu, x_gpu);
      } else {
         reducing_d_solve
            <REDUCING_D_SOLVE_THREADS_PER_BLOCK, false>
            <<<gpu->nrds, REDUCING_D_SOLVE_THREADS_PER_BLOCK, 0, *stream>>>
            (gpu->rds, work_gpu, x_gpu);
      }
      CudaCheckError();
   }

   if(gpu->ntrsv>0) {
      if(unit_diagonal) {
         trsv_lt_exec
            <double,TRSV_NB_TASK,THREADSX_TASK,THREADSY_TASK,true>
            <<<gpu->ntrsv, dim3(THREADSX_TASK,THREADSY_TASK), 0, *stream>>>
            (gpu->trsv, work_gpu, sync_gpu);
      } else {
         trsv_lt_exec
            <double,TRSV_NB_TASK,THREADSX_TASK,THREADSY_TASK,false>
            <<<gpu->ntrsv, dim3(THREADSX_TASK,THREADSY_TASK), 0, *stream>>>
            (gpu->trsv, work_gpu, sync_gpu);
      }
      CudaCheckError();
   }

   if(gpu->nscatter>0) {
      scatter
         <<<gpu->nscatter, SCATTER_NB, 0, *stream>>>
         (gpu->scatter, work_gpu, x_gpu);
      CudaCheckError();
   }
}

} // end extern "C"
