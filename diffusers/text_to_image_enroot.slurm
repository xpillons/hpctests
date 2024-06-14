#!/bin/bash
#SBATCH --job-name=text2image
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1          # crucial - only 1 task per dist per node!
#SBATCH --cpus-per-task=24
#SBATCH --gres=gpu:1
#SBATCH --partition=gpu
#SBATCH --output=%x-%j.out
#SBATCH --container-image nvcr.io\#nvidia/pytorch:24.03-py3
set -xe

export MODEL_NAME="CompVis/stable-diffusion-v1-4"
export DATASET_NAME="lambdalabs/naruto-blip-captions"

#source ~/.bashrc
#source ~/miniconda/bin/activate

cd ~/diffusers/
pip install .
pip install accelerate

cd examples/text_to_image
pip install -r requirements.txt

source ~/.bashrc

accelerate launch --mixed_precision="fp16" train_text_to_image.py \
                  --pretrained_model_name_or_path=$MODEL_NAME \
                  --dataset_name=$DATASET_NAME \
                  --use_ema \
                  --resolution=512 \
                  --center_crop \
                  --random_flip \
                  --train_batch_size=1 \
                  --gradient_accumulation_steps=4 \
                  --gradient_checkpointing \
                  --max_train_steps=15000 \
                  --learning_rate=1e-05 \
                  --max_grad_norm=1 \
                  --lr_scheduler="constant" \
                  --lr_warmup_steps=0 \
                  --output_dir="sd-pokemon-model2"