#!/bin/bash
#SBATCH --job-name=text2image_lora
#SBATCH --ntasks-per-node=1          # crucial - only 1 task per dist per node!
#SBATCH --output=%j.log
set -e

export MODEL_NAME="CompVis/stable-diffusion-v1-4"
export DATASET_NAME="lambdalabs/naruto-blip-captions"
OUTPUT_DIR_ROOT=$HOME
NB_GPUS=$(nvidia-smi -L | wc -l)

source ~/.bashrc
source ~/miniconda/bin/activate python38

cd ~/diffusers/examples/text_to_image
accelerate launch --mixed_precision="fp16" --num_processes=$NB_GPUS train_text_to_image_lora.py \
                  --pretrained_model_name_or_path=$MODEL_NAME \
                  --dataset_name=$DATASET_NAME --caption_column="text" \
                  --resolution=512 --random_flip \
                  --train_batch_size=1 \
                  --variant="fp16" --mixed_precision="fp16" \
                  --num_train_epochs=100 --checkpointing_steps=5000 \
                  --learning_rate=1e-04 --lr_scheduler="constant" --lr_warmup_steps=0 \
                  --seed=42 \
                  --output_dir="$OUTPUT_DIR_ROOT/sd-naruto-model-lora"

