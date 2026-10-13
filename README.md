# LTX-2.5 on RunPod Serverless

[LTX-2.5](https://huggingface.co/Lightricks/LTX-2.5) running in ComfyUI as a RunPod serverless worker. It generates video with synchronized audio from text or from an image. The sample requests go up to 1920x1088.

All model files are baked into the Docker image, so the endpoint needs no network volume and no Hugging Face token.

## What is in the image

| Part | File | Size |
| --- | --- | --- |
| Diffusion model (22B distilled, INT8) | `ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors` | 21.5 GB |
| Text encoder (Gemma 4 12B, INT8) | `gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors` | 15.4 GB |
| Prompt enhancer (Gemma 4 E2B, INT8) | `gemma4_e2b_it_int8_convrot.safetensors` | 5.2 GB |
| Video VAE | `ltx-2.5-video-vae-bf16.safetensors` | 1.5 GB |
| Latent upscaler (2x) | `ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors` | 1.0 GB |
| Audio VAE | `ltx-2.5-audio-vae-bf16.safetensors` | 0.4 GB |

These are the files ComfyUI's own LTX-2.5 templates load. The models total 44.9 GB.

The image also has ComfyUI v0.39.0 and PyTorch 2.14.1 built for CUDA 13.0.

### Where the weights come from

The official repo, [Lightricks/LTX-2.5](https://huggingface.co/Lightricks/LTX-2.5), is gated: its files only download with a Hugging Face token, and RunPod's GitHub build cannot be given one. The Dockerfile therefore takes the five LTX files from [osantinello/LTX25_Models](https://huggingface.co/osantinello/LTX25_Models), an ungated third-party copy, pinned to a commit so its content cannot change. The prompt enhancer comes from [Comfy-Org/gemma-4](https://huggingface.co/Comfy-Org/gemma-4), also pinned.

How far the copy has been checked against the official files:

- The video VAE, audio VAE and latent upscaler are byte-identical to the official ones.
- The diffusion model and text encoder have the official file sizes, but their hashes have not been compared.

To compare those two, read the official SHA-256 with a token whose account has access to the gated repo:

```bash
curl -sI -H "Authorization: Bearer hf_xxx" https://huggingface.co/Lightricks/LTX-2.5/resolve/main/diffusion_models/ltx-2.5-22b-distilled-transformer-comfy-int8-convrot.safetensors
curl -sI -H "Authorization: Bearer hf_xxx" https://huggingface.co/Lightricks/LTX-2.5/resolve/main/text_encoders/gemma4-12b-with-proj-ltx-2.5-comfy-int8-convrot.safetensors
```

The `x-linked-etag` header in each reply is the official hash. The copy holds:

| File | SHA-256 in the copy |
| --- | --- |
| Diffusion model | `c4279eeff115cbeaca494bd2183e7d768c38fe85a184dc6afbb7159157c44334` |
| Text encoder | `6ce688a0aa98a5fa36a9f1e6c3f42152a498cc2b53ee8c15674c64244f91487f` |

If the copy is ever deleted, rebuilds fail until `LTX_REPO` in the Dockerfile points somewhere else. Images that are already built keep working.

## Deploy

RunPod builds the image from this repo; nothing is built locally.

1. In the RunPod console, go to **Serverless → New Endpoint → Import Git Repository** and pick this repo, branch `main`, Dockerfile path `Dockerfile`.
2. Set the endpoint options below.
3. Deploy. To rebuild after a change, publish a new GitHub release.

| Setting | Value | Why |
| --- | --- | --- |
| Allowed CUDA Versions | `13.0` | The image's PyTorch needs NVIDIA driver 580 or newer. On an older host the worker exits at startup. |
| GPU | 48 GB | The diffusion model is 21.5 GB and the text encoder 15.4 GB. Smaller cards have not been tried. |
| Execution timeout | 1800 s to start | The default is 600 s, and the first job on a cold worker also loads about 40 GB of models. |
| Max workers | 1 while testing | |

Environment variables:

| Variable | Needed | Purpose |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Yes | S3 upload and Lambda callbacks |
| `BUCKET_NAME` | Yes, unless every request sends `data.bucketName` | Bucket for the output video |
| `AWS_REGION` | No, defaults to `ap-south-1` | |

RunPod's GitHub builds are limited to an 80 GB image, 160 minutes in total, and 30 minutes for the `docker build` step. Download speeds vary a lot between builds, so if one times out, start it again. If it keeps timing out while downloading models, build the image elsewhere and push it to a registry.

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

The LTX-2.5 weights are under the [LTX-2.x Community License Agreement](https://github.com/Lightricks/LTX-2/blob/main/LICENSE-2_x). That holds wherever they are downloaded from, so accept it on the [official model page](https://huggingface.co/Lightricks/LTX-2.5) and read it before putting this in front of users. The parts that affect a deployment:

- It is free to use, including as a hosted service, for organizations with under 10 million USD in yearly revenue. At or above that, a paid commercial agreement with Lightricks is required. Affiliates under common control are counted together.
- Users must be bound to the license's use restrictions.
- Safety, watermarking and provenance features must not be removed or bypassed, and generated content has to be disclosed as machine-generated.
- It does not allow using Lightricks' trademarks or implying their endorsement.

The prompt enhancer weights from Comfy-Org/gemma-4 are under Apache-2.0.

The worker code is based on [runpod-workers/worker-comfyui](https://github.com/runpod-workers/worker-comfyui) and is under the AGPL-3.0 ([LICENSE](LICENSE)).
