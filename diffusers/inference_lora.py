
from diffusers import StableDiffusionPipeline
import torch

model_path = "sd-naruto-model-lora"
pipe = StableDiffusionPipeline.from_pretrained("CompVis/stable-diffusion-v1-4", torch_dtype=torch.float16)
pipe.unet.load_attn_procs(model_path)
pipe.to("cuda")

prompt = "A dragon with green eyes"
image = pipe(prompt, num_inference_steps=30, guidance_scale=7.5).images[0]
image.save("naruto.png")
