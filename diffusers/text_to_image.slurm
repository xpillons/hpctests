#!/bin/bash
#SBATCH --job-name=text2image
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1          # crucial - only 1 task per dist per node!
#SBATCH --cpus-per-task=96
#SBATCH --gres=gpu:8
#SBATCH --partition=gpu
#SBATCH --output=%x-%j.out
set -xe

export MODEL_NAME="CompVis/stable-diffusion-v1-4"
export DATASET_NAME="lambdalabs/naruto-blip-captions"

source ~/.bashrc
source ~/miniconda/bin/activate python38

# This is not scaling on multi_gpu, use the LORA example instead

cd ~/diffusers/examples/text_to_image
accelerate launch --mixed_precision="fp16" --multi_gpu train_text_to_image.py \
                  --pretrained_model_name_or_path=$MODEL_NAME \
                  --dataset_name=$DATASET_NAME \
                  --use_ema \
                  --resolution=512 --center_crop --random_flip \
                  --train_batch_size=1 \
                  --gradient_accumulation_steps=4 \
                  --gradient_checkpointing \
                  --max_train_steps=15000 \
                  --learning_rate=1e-05 \
                  --max_grad_norm=1 \
                  --lr_scheduler="constant" --lr_warmup_steps=0 \
                  --output_dir="sd-pokemon-model"