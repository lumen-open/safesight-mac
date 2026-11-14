// SPDX-License-Identifier: Apache-2.0
// GENERATED from models/watcher-models.sha256 and models/thresholds.json; a test checks they match.
// The hash list and the cut-off table are sealed inside the signed app, so the watcher checks every
// model file against them before loading (register SD-223 (b)).

enum CommittedModelData {
    static let hashList = """
d7fb06e70cb56f4c93647b13633b5110b49cc477ba0928da77571e34ecbefafa  bumble-private-detector/bumble-private-detector.fp32.mlpackage/Data/com.apple.CoreML/model.mlmodel
1d8bf152c99ffbc8cd7445276c5f64ab52f91095c08d58167ada6478fd6fb744  bumble-private-detector/bumble-private-detector.fp32.mlpackage/Data/com.apple.CoreML/weights/weight.bin
e6939705f98a1b72bb2de758fb63abe408cc9381bb38f065a68f83b3e752bb5f  bumble-private-detector/bumble-private-detector.fp32.mlpackage/Manifest.json
7f8ed2ca9c7df7c7f728b3bb7141c73f9b97a33189cd930afab4571a43a94998  marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage/Data/com.apple.CoreML/model.mlmodel
25f0a6ee9ddd1c5756a87f3fc61e5c0ae40e3803a36b890369a47b372079ce2d  marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage/Data/com.apple.CoreML/weights/weight.bin
ce8389663040ae600b8c0662cb737ca64c17659a1b326605805e0e84a2efdeb7  marqo-vit-tiny-384/marqo-vit-tiny-384.mlpackage/Manifest.json
103b3c919f0a5588c06e71a589a3722f60a07ef7dfb955ee928ca196d6036a44  nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage/Data/com.apple.CoreML/model.mlmodel
ee6435b2edecae6599eba431a86a295243e2273037397393936be6421bfb83ae  nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage/Data/com.apple.CoreML/weights/weight.bin
45abee5af1cb8b94b6ef23fe98dd7eccdcac50f9bd0bb187b4ea168a0c479b69  nsfwjs-mobilenet-v2/nsfwjs-mobilenet-v2.mlpackage/Manifest.json
"""

    static let thresholdsJSON = #"""
{
 "schema": "kestrel-thresholds/1",
 "policy": "agreement+referee/1",
 "source": "screen-level tuning on pipeline tiles (q_pair=0.002, q_ref=0.005); provisional until the cloud run",
 "models": {
  "marqo-vit-tiny-384": {
   "16-31": {
    "cover": 0.8937,
    "clean": 0.2777,
    "strike": 0.9,
    "gridMember": 0.8937,
    "gridLow": 0.8937
   },
   "32-63": {
    "cover": 0.858,
    "clean": 0.4612,
    "strike": 0.9,
    "gridMember": 0.858,
    "gridLow": 0.858
   },
   "64-127": {
    "cover": 0.8235,
    "clean": 0.4524,
    "strike": 0.9,
    "gridMember": 0.8235,
    "gridLow": 0.8235
   },
   "128+": {
    "cover": 0.7583,
    "clean": 0.3444,
    "strike": 0.9,
    "gridMember": 0.7583,
    "gridLow": 0.7583
   }
  },
  "nsfwjs-mobilenet-v2": {
   "16-31": {
    "cover": 0.9768,
    "clean": 0.8313,
    "strike": 0.9768,
    "gridMember": 0.9768,
    "gridLow": 0.9768
   },
   "32-63": {
    "cover": 0.9948,
    "clean": 0.9265,
    "strike": 0.9948,
    "gridMember": 0.9948,
    "gridLow": 0.9948
   },
   "64-127": {
    "cover": 0.9963,
    "clean": 0.8571,
    "strike": 0.9963,
    "gridMember": 0.9963,
    "gridLow": 0.9963
   },
   "128+": {
    "cover": 0.934,
    "clean": 0.7867,
    "strike": 0.9652,
    "gridMember": 0.934,
    "gridLow": 0.934
   }
  },
  "bumble-private-detector": {
   "16-31": {
    "cover": 0.8647,
    "clean": 0.6106,
    "strike": 0.9,
    "gridMember": 0.8647,
    "gridLow": 0.8647
   },
   "32-63": {
    "cover": 0.9031,
    "clean": 0.6454,
    "strike": 0.9031,
    "gridMember": 0.9031,
    "gridLow": 0.9031
   },
   "64-127": {
    "cover": 0.891,
    "clean": 0.5508,
    "strike": 0.9,
    "gridMember": 0.891,
    "gridLow": 0.891
   },
   "128+": {
    "cover": 0.9075,
    "clean": 0.5089,
    "strike": 0.9075,
    "gridMember": 0.9075,
    "gridLow": 0.9075
   }
  }
 }
}
"""#
}
