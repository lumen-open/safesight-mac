# kestrel preprocessing spec, version `kestrel-preprocess/1`

Every model input in every place (screen watcher, browser, file scanner, cloud run) is made by
exactly these steps. In this repository the Swift version (`Sources/Preprocess/`) implements them,
and `PreprocessTests` checks that it produces **identical bytes** for every vector in
`spec/vectors/vectors.json`. Any other implementation (a browser extension or a file scanner, say)
must pass the same vectors. The project's detector lab, which isn't public yet, also has Python
and JavaScript versions, and checks the Python one against Pillow's `Image.resize(..., BILINEAR)`,
which these steps reproduce exactly.

Why one spec: v2 measured that scores move when preprocessing changes (Vision `scaleFill`,
nearest-neighbour, bilinear without antialiasing each gave different scores). An antialiased
filter also blunts image-scaling attacks, where a picture is crafted to look different once
shrunk by a non-antialiased resize.

All arithmetic on real numbers below is IEEE-754 double precision, using only `+ - * /`,
`floor`, `abs`, `min`, `max`, evaluated in the order written. These operations are exactly
rounded on every platform, so all three languages compute the same integers. Implementations
must not use fused multiply-add for these steps.

## 1. Input

An image `W x H` (both >= 1) of 8-bit channels, straight (not premultiplied) alpha, in RGBA
order. A BGRA capture buffer is reordered to RGBA first (a byte permutation). An opaque
premultiplied buffer equals its straight form.

## 2. Alpha over black

For each pixel and each colour channel `c` with alpha `a`:
`c' = floor((c * a + 127) / 255)` (integer division). Opaque pixels are unchanged. Alpha is
then dropped.

## 3. Crop

A rectangle `(x, y, w, h)` of integers with `w, h >= 1`, `0 <= x`, `x + w <= W`, `0 <= y`,
`y + h <= H`. Callers clamp; the spec refuses anything outside.

## 4. Resample to `N x N`

Width and height are resampled independently (the picture is squashed, not padded or cropped;
callers keep the aspect ratio of a judged tile at or below 2:1 by splitting long tiles). First
every row is resampled from `w` to `N` columns, giving an intermediate `h x N` image of bytes;
then every column of that is resampled from `h` to `N` rows.

For one axis from `S` input samples to `D` output samples:

```
scale = S / D
fscale = max(scale, 1.0)
support = fscale            # triangle filter of radius 1, widened when shrinking
for i in 0 .. D-1:
    center = (i + 0.5) * scale
    lo = max(0, floor(center - support + 0.5))
    hi = min(S, floor(center + support + 0.5))
    for j in lo .. hi-1:
        t = (j - center + 0.5) / fscale
        w[j] = max(0.0, 1.0 - abs(t))
    total = sum of w[j] in increasing j
    for j: k[j] = floor(w[j] / total * 4194304 + 0.5)        # 4194304 = 2^22
```

If `total` is 0 the weights stay 0 (this cannot happen for `S, D >= 1` but is defined).
Each output sample is
`v = floor((sum_j k[j] * in[j] + 2097152) / 4194304)` clamped to `0 .. 255`, computed in
integers (the sum fits in 32 bits; JavaScript may use doubles since all values are integers
below 2^53).

## 5. Jitter (before every judgement; optional only in parity and vector runs)

A seeded 32-bit xorshift generator:
```
next(): x ^= (x << 13) mod 2^32;  x ^= x >> 17;  x ^= (x << 5) mod 2^32;  return x
```
The seed must not be 0 (0 is replaced by `0x9E3779B9`).

* **Geometric:** with `m = floor(min(w, h) * 3 / 100)` (integer), if `m > 0` draw in order
  `dx0 = next() mod (m+1)`, `dy0`, `dx1`, `dy1` the same way, and judge the rectangle
  `(x + dx0, y + dy0, w - dx0 - dx1, h - dy0 - dy1)` instead. At most 3% is trimmed from each
  side, so nothing that matters is lost, but the resampling phase changes every time.
* **Value noise:** after step 4, for each output byte in tensor order (step 6), draw
  `r = next() mod 3` and set `v = clamp(v + r - 1, 0, 255)`.

The geometric draws come first, then the noise draws, from the same generator. In the product the
seed comes from the system random source for every judgement; tests pass fixed seeds.

## 6. Tensor

Planar RGB, channel-major (`[3][N][N]`), each value the byte from step 4 or 5 as a number in
`0 .. 255` (float32, or float16, which holds these integers exactly). Model-specific scaling
(for example `x / 255`, `(x - 127.5) / 127.5`, `(x - 128) / 128`) is built into each converted
model file, so the runtime never applies it. Test vectors hash this byte tensor (`3*N*N` bytes,
channel-major) with SHA-256.

## 7. Test inputs

Vector inputs are generated, not stored. With the same xorshift generator seeded by the
vector's `seed`:
* `noise`: each byte of the RGBA image, in row-major RGBA order, is `next() & 255`.
* `noise-opaque`: as `noise`, but alpha is forced to 255.
* `gradient`: `R = floor(255 * x / max(W-1,1))`, `G = floor(255 * y / max(H-1,1))`,
  `B = (x * 7 + y * 13) & 255`, `A = 255` (no generator).
* `checker`: 8-pixel checkerboard of `(250, 250, 250)` and `(5, 5, 5)`, `A = 255`.
