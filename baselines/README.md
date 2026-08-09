# Phase 0 baselines

Regression oracle captured before any denoiser / pipeline work began. If a
later change is supposed to be performance-neutral or image-neutral, it gets
compared against these.

Captured **2026-08-09** with the rayquery fork built at `016f606ee`
(`build-love12/love/Release/love.exe`), Vulkan renderer, AMD Radeon RX 6950 XT,
Windows 11. The `love12-runtime/` folder at the repo root is an OLDER build
without rayquery — do not benchmark against it.

## Files

| file | what it is |
|---|---|
| `bench-base0.txt` | fresh baseline matrix (tag `base0`), 300 frames per run after 30 warmup |
| `bench-pre-phase0.txt` | historical runs found in the save directory (`b1`–`b8` are the bounce-sweep rows behind HARDWARE_RAYTRACING.md) |
| `shot-pt-sdf-600spp.png` | SDF path tracer, 600 samples, default camera, 1280×720, no HUD |
| `shot-pt-hw-600spp.png` | hardware path tracer, same conditions |
| `shot-deferred-240acc.png` | deferred pipeline, 240 accumulated frames, same camera |

`bench.txt` columns: tag, tracer, bounces, frames, render size, elapsed s,
fps, ms/frame.

## Reproducing

From the project directory, with the fork's love.exe:

```
love . --pt --bench 300 --bounces 8 --scale 2.0 --tag base0   # SDF
love . --hw --bench 300 --bounces 8 --scale 2.0 --tag base0   # hardware
love . --bench 300 --scale 1.0 --tag base0-deferred           # deferred
love . --pt --shot 600 --nohud                                # screenshot
```

Resolution sweep uses `--scale 2.0 / 2.5 / 3.0` against the fixed 1280×720
window (the CLI scale is not clamped to the keyboard's 2.0 limit). Results are
appended to `bench.txt` / written as `shot.png` in the LÖVE save directory
(`%APPDATA%\LOVE\cornellbox-gi`).

## Phase 1 additions (denoiser)

| file | what it is |
|---|---|
| `bench-phase1.txt` | denoised-mode benches (tag `ph1`) + a reference-mode regression row |
| `shot-dn-hw-static.png` | denoised 1 spp, hardware rays, 120 frames, static camera |
| `shot-dn-hw-orbit.png` | same but captured mid-orbit — the shot the old accumulation could not take |

Phase 1 regression facts: post-refactor reference screenshots are **bit-identical**
to the Phase 0 baselines (MAD 0, both tracers), reference bench unchanged
(3.22 vs 3.20 ms), denoised-vs-converged MAD 1.22%/255 at 1280×720.

## Phase 2 facts (fork: acceleration structure update/refit)

The fork gained `{ updatable = true }` at creation plus `tlas:update{instances}`
and `blas:update()` (refit). Verified by `probes/rq_update` — TLAS transform
moves, BLAS refit after `Buffer:setArrayData`, combined, error paths, and
timing: **0.004 ms CPU to record an update, ~0.024 ms GPU each** (300 updates +
trace flushed in 7.3 ms), no allocations after build. Regression on the new
binary: compute probe PASS, HW reference shot **bit-identical** to Phase 0,
bench within noise (3.16 vs 3.20 ms reference, 10.49 vs 10.82 ms denoised).

## Phase 3 facts (dynamic block)

The tall block became its own local-space BLAS placed by an updatable-TLAS
instance transform; `--anim` / `B` spins it with one `tlas:update()` per frame.
`bench-phase3.txt`: animated denoised 10.87 ms vs 10.49 static, animated
reference 3.44 vs 3.22 — the whole per-frame refit costs ~0.2-0.4 ms in situ.
Static regression with the instanced block: MAD 0.000% vs `shot-pt-hw-600spp.png`
(max single-channel diff 2/255, float precision in the instance transform).
`shot-dn-hw-anim.png` is a mid-spin denoised frame.

## Phase 4 facts (hybrid deferred pipeline)

RT shadows / RTAO / RT reflections replace the screen-space passes behind
`F2/F3/F4/T` (`--rt`). `bench-phase4.txt`: all three ray-traced costs the same
as screen-space — 2.61 vs 2.54 ms at 720p, 15.59 vs 15.84 ms at 1440p (RT
marginally faster). `shot-deferred-rt-240acc.png` is the full hybrid frame;
`shot-ssr-isolated-{ss,rt}.png` isolate reflections — the RT sphere's lower
half reflects lit geometry where the SS version goes dark. Post-refactor
(rq_common.glsl extraction) HW reference: MAD 0.0000, max 2/255 vs baseline.

## Phase 5 facts (fork polish + specular reprojection)

Fork: multi-geometry BLAS (per-geometry build/refit ranges), BLAS compaction
behind `{ compact = true }`, and a fixed latent bug — re-sending a different
TLAS to a shader never marked its descriptor set dirty, so the shader kept
tracing the old structure (found by `probes/rq_multi`, see
`probe-phase5-multi.txt`). Cornell scene structures with compaction:
**648.4 → 232.7 KB**, reference image unchanged (MAD 0.0000, max 2/255).

Demo: mirror pixels now reproject by **virtual depth** (surface t + reflected
hit t, carried in the denoise driver's alpha), validated by material id;
metal history cap raised 8 → 32. `shot-dn-hw-orbit-v2.png` vs the Phase 1
`shot-dn-hw-orbit.png` shows the sphere's reflections crisp mid-orbit.
Denoised bench unchanged: 10.95 ms at 1440p (`bench-phase5.txt`).

Deferred by design: batched builds and a Mesh convenience constructor — both
were conditioned on real usage that still does not exist.

## Headline numbers (base0, 8 bounces)

| render size | SDF | hardware | ratio |
|---|---|---|---|
| 2560×1440 | 11.94 ms | 3.20 ms | 3.73× |
| 3200×1800 | 18.36 ms | 4.78 ms | 3.84× |
| 3840×2160 | 26.08 ms | 6.62 ms | 3.94× |

Deferred pipeline: 2.59 ms at 1280×720, 15.90 ms at 2560×1440.

These match HARDWARE_RAYTRACING.md within run-to-run noise, which is the point:
the baseline is trustworthy.
