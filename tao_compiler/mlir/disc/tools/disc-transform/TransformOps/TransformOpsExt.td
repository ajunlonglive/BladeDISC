// Copyright 2022 The BladeDISC Authors. All rights reserved.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef DISC_TRANSFORM_OPS_EXT
#define DISC_TRANSFORM_OPS_EXT

include "mlir/Dialect/PDL/IR/PDLTypes.td"
include "mlir/Dialect/Transform/IR/TransformAttrs.td"
include "mlir/Dialect/Transform/IR/TransformDialect.td"
include "mlir/Dialect/Transform/IR/TransformInterfaces.td"
include "mlir/Interfaces/ControlFlowInterfaces.td"
include "mlir/Interfaces/SideEffectInterfaces.td"
include "mlir/IR/OpAsmInterface.td"
include "mlir/IR/OpBase.td"

def DISCBufferizeOp : Op<Transform_Dialect, "disc.bufferize",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     DeclareOpInterfaceMethods<TransformOpInterface>]> {
  let description = [{
    Target the whole module op and call upstream comprehensive bufferize with extra DISC hooks.

    Return modes:
    =============
    This operation calls the upstream one-shot bufferization pass with extra
    registered patterns for DISC.

    The pass is ran on all the ModuleOp nested under the top-level op on which
    the transform dialect interpreter pass is applied.

    If any of the pass on any of the ModuleOp fails, the transformation
    definitely fails. Otherwise the transformation succeeds.

    No handles are consumed or produced.
  }];

  let arguments = (ins PDL_Operation:$target);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "attr-dict $target";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";
}

def ApplyPatternsOp : Op<Transform_Dialect, "disc.apply_patterns",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Greedily applies patterns as specified by its attributes.

    Must be applied to an op with trait IsolatedFromAbove since the
    GreedyPatternRewriter asserts those.

    Returns the IsolatedFromAbove op whose content it has modified for better
    chaining APIs.

    The following additive attributes can be set, they add patterns in an
    unspecified order:
      - canonicalization: adds all the canonicalization patterns of all
      registered dialects and ops.

    Return modes:
    =============
    This operation applies a number of patterns to rewrite vector IR into
    distributed warp form. To apply these patterns, this operation must target
    an operation that is isolated from above, otherwise the transform definitely
    fails.

    If the pattern application fails, or if the underlying listener fails to
    capture op handles, the transformation definitely fails.

    Otherwise the transformation is successful and no result is returned.
  }];

  let arguments = (ins PDL_Operation:$target,
                       UnitAttr:$canonicalization);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    // TODO: Some bitvector to scale better than n-bools.
    OpBuilder<(ins "Value":$target, "bool":$canonicalization)>
  ];

  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

def FoldProducerExtractSliceOp : Op<Transform_Dialect, "disc.fold_producer_extract_slice",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Given a tensor.ExtractSliceOp, greedily fold its producers if they are also tensor.ExtractSliceOp.

    Returns the folded new tensor.ExtractSliceOp.

    The following additive attributes can be set:
      - max_repeat_num: fold at most `max_repeat_num` times.

    Return modes:
    =============
    This operation try to fold two tensor.ExtractSliceOp with def-use relationship at most
    `max_repeat_num` times.
  }];

  let arguments = (ins PDL_Operation:$target,
                       I64Attr:$max_repeat_num);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    OpBuilder<(ins "Value":$target, "int64_t":$max_repeat_num)>
  ];

  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

def CacheReadOp : Op<Transform_Dialect, "disc.cache_read",
    [DeclareOpInterfaceMethods<MemoryEffectsOpInterface>,
     DeclareOpInterfaceMethods<TransformOpInterface>]> {
  let description = [{
    Given a target `tensor.ExtractSliceOp` named 's0', first tile and pack source of the `s0`,
    and then replace `s0` with a new `tensor.ExtractSliceOp` named `s1`. `s1` will read from
    the packed and tiled source to increase the cache hit ratio. the transformed source tensor
    will be placed right before the `anthor` op.

    Returns the new tensor.ExtractSliceOp.

    The following attributes need to be set:
      - tileLevels: please see the document of `disc_ral::disc_linalg_ext::MultiLevelPackOp`
      - tileSizes: please see the document of `disc_ral::disc_linalg_ext::MultiLevelPackOp`
      - permutation: please see the document of `disc_ral::disc_linalg_ext::MultiLevelPackOp`
      - padded (optional): indicates that the slice op is padded and target tile is the padded
        version.

    Example #0:
     convert from:
     ```
      for (i, j) {
        %0 = tensor.extract_slice %arg0[i, j][32, 32][1, 1] : tensor<256x256xf32> to tensor<32x32xf32>
        use(%0)
      }
     ```
     to:
     ```
      %0 = tensor.empty() : tensor<8x8x32x32xf32>
      %packed = disc_linalg_ext.multi_level_pack %arg0 with
          tile_levels = [1, 1] tile_sizes = [32, 32] permutation = [0, 3, 1, 3] into %0
          (tensor<256x256xf32> tensor<8x8x32x32xf32>) -> tensor<8x8x32x32xf32>
      for (i, j) {
        i', j' = f(i, j) // index mapping
        %0 = tensor.extract_slice %packed[i', j', 0, 0][1, 1, 32, 32][1, 1, 1, 1] : tensor<8x8x32x32xf32> to tensor<32x32xf32>
        use(%0)
      }
     ```

    Example #1:
     convert from:
     ```
      #map = affine_map<(d0)[s0] -> (-d0 + s0, 32)>
      %cst0 = arith.constant 0.000000e+00 : f32
      for (i, j) {
        %s0 = affine.min #map(%i)[%d0]
        %s1 = affine.min #map(%j)[%d1]
        %0 = tensor.extract_slice %arg0[i, j][%s0, %s1][1, 1] : tensor<?x?xf32> to tensor<?x?xf32>
        %1 = tensor.pad %0 low[0, 0] high[32, 32] {
        ^bb0(%arg12: index, %arg13: index):
          tensor.yield %cst0 : f32
        } : tensor<?x?xf32> to tensor<32x32xf32>
        use(%1)
      }
     ```
     to:
     ```
      %0 = tensor.empty() : tensor<?x?x32x32xf32>
      %packed = disc_linalg_ext.multi_level_pack %arg0 with
          %cst0 tile_levels = [1, 1] tile_sizes = [32, 32] permutation = [0, 3, 1, 3] into %0
          (tensor<?x?xf32> tensor<?x?x32x32xf32>) -> tensor<?x?x32x32xf32>
      for (i, j) {
        i', j' = f(i, j) // index mapping
        %0 = tensor.extract_slice %packed[i', j', 0, 0][1, 1, 32, 32][1, 1, 1, 1] : tensor<?x?x32x32xf32> to tensor<32x32xf32>
        use(%0)
      }
     ```
  }];

  let arguments = (ins PDL_Operation:$target,
                       PDL_Operation:$anchor,
                       I64ArrayAttr:$tile_levels,
                       I64ArrayAttr:$tile_sizes,
                       I64ArrayAttr:$permutation,
                       UnitAttr:$padded);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = [{
    attr-dict
    $target `at` $anchor `with`
    `tile_levels` `=` $tile_levels
    `tile_sizes` `=` $tile_sizes
    `permutation` `=` $permutation
  }];
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    OpBuilder<(ins "Value":$target, "Value":$anchor,
                   "ArrayRef<int64_t>":$tileLevels,
                   "ArrayRef<int64_t>":$tileSizes,
                   CArg<"bool", "false">:$padded,
                   CArg<"ArrayRef<int64_t>", "{}">:$permutation)>
  ];
}

def LowerMultiLevelPackToLoopOp : Op<Transform_Dialect, "disc.lower_multi_level_pack_to_loop",
    [FunctionalStyleTransformOpTrait,
     MemoryEffectsOpInterface,
     TransformEachOpTrait,
     TransformOpInterface]> {
  let description = [{
    Replace a MultiLevelPackOp to its loop level equivalent.

    Returns a handle to the outter most loop.
  }];

  let arguments = (ins PDL_Operation:$target);
  let results = (outs PDL_Operation:$result);

  let assemblyFormat = "$target attr-dict";
  let cppNamespace = "::mlir::disc_ral::transform_dialect";

  let builders = [
    OpBuilder<(ins "Value":$target)>
  ];

  let extraClassDeclaration = [{
    ::mlir::DiagnosedSilenceableFailure applyToOne(
        ::mlir::Operation *target,
        ::llvm::SmallVectorImpl<::mlir::Operation *> &results,
        ::mlir::transform::TransformState &state);
  }];
}

#endif // DISC_TRANSFORM_OPS_EXT
