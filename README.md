# LTX-2.5 on RunPod Serverless

[LTX-2.5](https://huggingface.co/Lightricks/LTX-2.5) running in ComfyUI as a RunPod serverless worker. It generates video with synchronized audio from text or from an image. The sample requests go up to 1920x1088.

## What the worker loads

| Part | File | Size |
| --- | --- | --- |
| Diffusion model (22B distilled, INT8) | `ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors` | 21.5 GB |
| Text encoder (Gemma 4 12B, INT8) | `gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors` | 15.4 GB |
| Prompt enhancer (Gemma 4 E2B, INT8) | `gemma4_e2b_it_int8_convrot.safetensors` | 5.2 GB |
| Video VAE | `ltx-2.5-video-vae-bf16.safetensors` | 1.5 GB |
| Latent upscaler (2x) | `ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors` | 1.0 GB |
| Audio VAE | `ltx-2.5-audio-vae-bf16.safetensors` | 0.4 GB |

These are the files ComfyUI's own LTX-2.5 templates load. They come from [Lightricks/LTX-2.5](https://huggingface.co/Lightricks/LTX-2.5) and, for the prompt enhancer, [Comfy-Org/gemma-4](https://huggingface.co/Comfy-Org/gemma-4), both at pinned revisions. The models total 44.9 GB. The list lives in [src/download_models.sh](src/download_models.sh).

The image also has ComfyUI v0.39.0 and PyTorch 2.14.1 built for CUDA 13.0.

## Hugging Face access

Unlike the MiniMax H3 and Wan workers, this one needs a Hugging Face token. `Lightricks/LTX-2.5` is a gated repo, and its files return 401 without one.

1. Sign in to Hugging Face, open the [model page](https://huggingface.co/Lightricks/LTX-2.5) and click **Agree and Access**.
2. Create a read token for that account under **Settings → Access Tokens**.

Where the token goes depends on how you deploy.

## Deploy

### Option A: RunPod builds from GitHub, models on a network volume

RunPod's GitHub build has no documented way to pass a build argument or secret, so it builds the image without models. The worker then downloads them the first time it starts.

1. Create a network volume of at least 60 GB in the data center you will use.
2. In the RunPod console, go to **Serverless → New Endpoint → Import Git Repository** and pick this repo, branch `main`, Dockerfile path `Dockerfile`.
3. Attach the network volume, add `HF_TOKEN` as an environment variable, and set the endpoint options below.
4. Keep max workers at 1 and send [test_input.json](test_input.json). The first worker downloads the models to `/runpod-volume/ltx-2.5/models`, which adds several minutes to that one start.
5. Raise max workers. Later workers find the files on the volume and download nothing.

To rebuild after a change, publish a new GitHub release.

Without a network volume the worker still starts, but it downloads all 44.9 GB to the container disk on every cold start, and the container disk must be at least 60 GB. Use that only for a quick test.

### Option B: models baked into the image

Build the image somewhere you can pass the token, push it to a registry, and create the endpoint from that image. The endpoint then needs no network volume and no `HF_TOKEN`.

```bash
docker build --platform linux/amd64 --build-arg HF_TOKEN=hf_xxx -t <registry>/runpod-ltx-2.5:latest .
docker push <registry>/runpod-ltx-2.5:latest
```

A build argument is recorded in the image history, so anyone who can pull the image can read the token. Use a fine-grained token that can only read this one repo, and keep the image in a private registry.

### Endpoint settings

| Setting | Value | Why |
| --- | --- | --- |
| Allowed CUDA Versions | `13.0` | The image's PyTorch needs NVIDIA driver 580 or newer. On an older host the worker exits at startup. |
| GPU | 48 GB | The diffusion model is 21.5 GB and the text encoder 15.4 GB. Smaller cards have not been tried. |
| Network volume | Option A only | Holds the models so they are downloaded once. |
| Execution timeout | 1800 s to start | The default is 600 s, and the first job on a cold worker also loads about 40 GB of models. |
| Max workers | 1 while testing | With option A it also keeps two workers from downloading the same files at once. |

Environment variables:

| Variable | Needed | Purpose |
| --- | --- | --- |
| `HF_TOKEN` | Option A | Downloads the gated model files when the worker starts |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Yes | S3 upload and Lambda callbacks |
| `BUCKET_NAME` | Yes, unless every request sends `data.bucketName` | Bucket for the output video |
| `AWS_REGION` | No, defaults to `ap-south-1` | |

## Request

The request format is the same as the MiniMax H3 and Wan endpoints: a ComfyUI API-format graph in `input.workflow`, optional input images, and an optional `data` block for the backend callbacks.

```json
{
  "input": {
    "workflow": { },
    "images": [{ "name": "input.png", "image": "<base64>" }],
    "data": {
      "workflowId": "...",
      "generationId": "...",
      "bucketName": "...",
      "triggerFunc": "...",
      "failureFunc": "..."
    }
  }
}
```

Three ready-made requests are in the repo:

- [test_input.json](test_input.json): text to video, 832x512, 5 seconds. Small and quick, for a first test.
- [sample-req-t2v.json](sample-req-t2v.json): text to video, 1920x1088, 5 seconds.
- [sample-req-i2v.json](sample-req-i2v.json): image to video, 1920x1088, 5 seconds. Replace `<BASE64_IMAGE>` with a real image.

The same two 1920x1088 graphs are also in [workflow-t2v.json](workflow-t2v.json) and [workflow-i2v.json](workflow-i2v.json) on their own, without the request wrapper. Each is the value to send as `input.workflow`.

They are ComfyUI's published LTX-2.5 graphs (`video_ltx2_5_t2v` and `video_ltx2_5_i2v`) in API format, with two changes besides the values below:

- The `PreviewAny` node is removed. It is a second output node, and with two outputs ComfyUI accepts a request whose video branch failed validation, runs only the preview, and reports success with no video. With one output, a bad request is rejected and the failure callback fires.
- `ResolutionSelector` rounds to a multiple of 64 instead of 32. See [Resolution](#resolution).

The output is an MP4 at 24 fps with audio. It is uploaded to `outputs/{workflowId}/{generationId}.mp4`, or to `videos/{uuid}.mp4` when the request has no `data` block. The job returns `{"status": "success", "s3_url": "...", "job_id": "..."}`.

### What to change in the graph

The two graphs use different node ids for the same settings.

| Setting | Text to video | Image to video | Input | Meaning |
| --- | --- | --- | --- | --- |
| Prompt | `405:376` | `398:376` | `value` | One paragraph covering the scene, the action in order, the camera, the lighting and the sound. LTX-2.5 follows long, specific prompts best. |
| Aspect ratio | `409` | `403` | `aspect_ratio` | One of `16:9 (Widescreen)`, `9:16 (Portrait Widescreen)`, `1:1 (Square)`, `4:3 (Standard)`, `3:4 (Portrait Standard)`, `3:2 (Photo)`, `2:3 (Portrait Photo)`, `21:9 (Ultrawide)`. |
| Size | `409` | `403` | `megapixels` | See [Resolution](#resolution). |
| Duration | `405:362` | `398:362` | `value` | Length in whole seconds. |
| Frame rate | `405:361` | `398:361` | `value` | Frames per second. |
| Seed | `405:339` | `398:339` | `noise_seed` | Seed. |
| Prompt enhancer | `405:383` | `398:383` | `value` | `true` rewrites the prompt with Gemma 4 before generating. Meant for short prompts. ComfyUI's notes say it adds 1 to 2 minutes. |
| First frame | | `395` | `image` | The name of the uploaded image. |

The video has `duration × frame rate + 1` frames, and the model works in steps of 8 frames. Keep `duration × frame rate` a multiple of 8, which is always true at 24 fps.

For image to video, the image is scaled until its longer side is 1536 pixels (node `398:351`) and then centre-cropped to the output shape, so pick the `aspect_ratio` that matches the image.

ComfyUI also publishes a first-and-last-frame graph, `video_ltx2_5_flf2v`, that runs on the same models. It is not included here.

### Resolution

Each video is generated in two passes: once at half size, then again at full size after the latent upscaler doubles it. The half-size pass sits on a 32-pixel grid, so the width and height that come out are always multiples of 64. `ResolutionSelector` is set to `multiple: 64` so the size it picks is the size you get. With the template's `32`, a request for 1280x736 comes out as 1280x704.

Sizes at 16:9:

| `megapixels` | Output |
| --- | --- |
| `0.4` | 832x512 |
| `0.9` | 1280x704 |
| `1.5` | 1664x960 |
| `2.0` | 1920x1088 |

ComfyUI's own size table for these graphs stops at `2.0`. The graph accepts more, and `8.0` gives 3840x2176, but nothing above 1920x1088 has been run on this worker. Expect it to need more VRAM and a longer execution timeout.

## License

The LTX-2.5 weights are under the [LTX-2.x Community License Agreement](https://github.com/Lightricks/LTX-2/blob/main/LICENSE-2_x). Read it before putting this in front of users. The parts that affect a deployment:

- It is free to use, including as a hosted service, for organizations with under 10 million USD in yearly revenue. At or above that, a paid commercial agreement with Lightricks is required. Affiliates under common control are counted together.
- Users must be bound to the license's use restrictions.
- Safety, watermarking and provenance features must not be removed or bypassed, and generated content has to be disclosed as machine-generated.
- It does not allow using Lightricks' trademarks or implying their endorsement.

The prompt enhancer weights from Comfy-Org/gemma-4 are under Apache-2.0.

The worker code is based on [runpod-workers/worker-comfyui](https://github.com/runpod-workers/worker-comfyui) and is under the AGPL-3.0 ([LICENSE](LICENSE)).
