# Hardware ray tracing vs SDF sphere marching

The path tracer in this project finds surfaces by sphere marching a signed
distance field. This adds a second path tracer that asks the same questions of
**hardware ray tracing** instead, and measures the difference.

It needs a LÖVE build with `love.graphics.getSupported().rayquery` — the
`rayquery` branch of [MichaelLT38/love](https://github.com/MichaelLT38/love),
which adds `VK_KHR_ray_query` support, `love.graphics.newAccelerationStructure`,
and `#pragma rayquery` in shaders. On stock LÖVE 12 nothing here activates and
the SDF path tracer runs exactly as before.

```
love . --hw          # path traced view, hardware ray queries
love . --pt          # path traced view, SDF sphere marching (unchanged)
H                    # toggle between them live
```

## Headline

On an **AMD Radeon RX 6950 XT** (Vulkan 1.4.315), 8 bounces:

| | |
|---|---|
| marginal cost per pixel | **4.15× cheaper** — 3.04 ns → 0.73 ns |
| whole frame at 3840×2160 | **3.90× faster** — 25.98 ms → 6.67 ms |
| samples/sec at 3840×2160 | **38.5 → 150.0** |

Same image: **0.30% mean absolute difference**, and the difference is
Monte-Carlo noise plus one-pixel edges, not structure.

## What changed, and what deliberately did not

`shaders/pathtrace_hw.glsl` is a copy of `shaders/pathtrace.glsl` with the
integrator untouched — same next-event estimation, same GGX lobe choice, same
Russian roulette, same firefly clamp, same seeding. Only the intersector
differs, so any difference in the image or the clock is attributable to it.

| | SDF | hardware |
|---|---|---|
| closest hit | up to 160 sphere-marching steps, each evaluating all 9 primitives | one `rayQueryEXT` traversal |
| normal | 4 more `map()` calls for a gradient | the hit triangle's own normal, interpolated by barycentrics |
| shadow ray | up to 96 `mapOcc()` steps | one `rayQueryEXT` with `TerminateOnFirstHit` |

Roughly **2,200 primitive evaluations per bounce** in shader ALU, replaced by
two ray queries in dedicated traversal hardware.

`rt_scene.lua` transcribes `mapEx()` into triangles: **4,064 triangles**
(5 wall slabs, 2 rotated blocks, a 64×32 sphere, the emitter quad) and
**648 KB** of acceleration structures.

The SDF's `map()` / `mapOcc()` split — shadow rays must not stop on the light
itself — becomes an **instance mask**. The emitter is its own instance and does
not set bit 0; shadow rays are issued with cull mask `0x01` and never see it.
Same rule, expressed to the traversal hardware rather than to a branch.

## Correctness

600 samples, identical camera.

| | |
|---|---|
| mean absolute difference | 0.772 / 255 (**0.30%**) |
| RMSE | 3.317 / 255 |
| pixels differing by more than 8/255 | 2.90% |
| pixels differing by more than 32/255 | 0.36% |

The amplified difference image is the more useful result: uniform speckle
(Monte-Carlo noise — the two runs draw different random sequences), plus
one-pixel-wide lines on every geometric edge, plus a brighter ring on the
sphere silhouette where 4,096 triangles approximate an analytic sphere.

**The block faces are dark.** That is the check that matters: `mapEx` evaluates
its two rotated blocks in a rotated *frame*, so the world-space box is the
centre plus the **inverse** rotation of its local corners. Getting that
backwards still looks like a Cornell box and is wrong in every reflection — and
it would light up whole faces in the diff, not just their edges.

## Performance

`--bench N` measures the current mode over N frames after 30 discarded warmup
frames, then quits. The two path tracers are compared by running the app twice
rather than by switching mid-run, so no shader swap or cache effect lands in the
numbers.

### There is a floor, and it hides most of the win

At 160×90 with 8 bounces **both** paths measure 2.06 ms. That is fixed
per-frame cost — resolve pass, present, CPU frame time — and nothing to do with
tracing. Any measurement near it understates the difference, and at 1280×720
the hardware path is *entirely* inside it.

This is why the naive first measurement said "13% faster". It was measuring the
floor.

### Resolution, 8 bounces

| render size | SDF | hardware | ratio |
|---|---|---|---|
| 1280×720 | 3.22 ms | 2.08 ms | 1.55× ← hw at the floor |
| 1920×1080 | 6.92 ms | 2.20 ms | 3.14× ← hw at the floor |
| 2560×1440 | 11.97 ms | 3.29 ms | 3.64× |
| 3200×1800 | 18.36 ms | 4.81 ms | 3.81× |
| 3840×2160 | 25.98 ms | 6.67 ms | 3.90× |

Fitting only the three points where both paths are genuinely GPU-bound gives the
number that is not contaminated by the floor:

```
SDF       3.04 ns / pixel
hardware  0.73 ns / pixel
                            slope ratio  4.15x
```

### Bounce depth, at 2560×1440

| bounces | SDF | hardware | ratio |
|---|---|---|---|
| 1 | 1.95 ms | 2.17 ms | **0.90×** |
| 2 | 4.41 ms | 2.05 ms | 2.15× |
| 3 | 7.06 ms | 2.02 ms | 3.49× |
| 5 | 9.94 ms | 2.62 ms | 3.79× |
| 8 | 11.98 ms | 3.26 ms | 3.67× |

**At one bounce the hardware path is slightly slower**, and that is worth
stating rather than hiding. With a single primary ray there is nothing to
amortise the acceleration structure against, both paths are sitting on the
2.06 ms floor, and the difference is inside the noise there. The advantage
appears at two bounces and is decisive by three.

## Caveats

* **One GPU, one scene.** RDNA2 has hardware ray accelerators; an older card
  without them would report `rayquery = false` and never reach this path.
* **The SDF is not a strawman, but it is not optimised either.** It is the
  scene's own `mapEx()` with its original 160/96 step limits. A hand-tuned
  marcher with tighter bounds would close some of the gap — though not the part
  that comes from evaluating nine primitives per step.
* **The scene is small.** 4,064 triangles is nothing for a BVH; the advantage
  would grow with scene complexity, because a BVH is logarithmic in primitive
  count where `mapEx()` is linear.
* **The sphere is tessellated, the SDF's is analytic.** That is the one
  intentional geometric difference and it is visible only on the silhouette.
* Timings are whole-frame wall clock, so the resolve pass and present are
  included — which is exactly why the slope, not the ratio, is the headline.
