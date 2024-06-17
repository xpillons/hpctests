#!/bin/bash

# None of the containers provided here https://docs.nvidia.com/deeplearning/frameworks/pytorch-release-notes/overview.html seems to works !!!

#SBATCH --job-name=text2image
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1          # crucial - only 1 task per dist per node!
#SBATCH --cpus-per-task=24
#SBATCH --gres=gpu:1
#SBATCH --partition=gpu
#SBATCH --output=%x-%j.out
#SBATCH --container-image nvcr.io\#nvidia/pytorch:24.05-py3
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

#torchtext 0.17.0a0 requires torch==2.3.0a0+40ec155e58, but you have torch 2.3.0a0+40ec155e58.nv24.3 which is incompatible

accelerate launch --mixed_precision="fp16" train_text_to_image.py \
                  --pretrained_model_name_or_path=$MODEL_NAME \
                  --dataset_name=$DATASET_NAME \
                  --multi_gpu \
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

# When run with SBATCH here is the error I'm getting. While running the same commands in an interactive container session, it works fine.

# Traceback (most recent call last):
#   File "/shared/home/hpcadmin/diffusers/examples/text_to_image/train_text_to_image.py", line 1123, in <module>
#     main()
#   File "/shared/home/hpcadmin/diffusers/examples/text_to_image/train_text_to_image.py", line 539, in main
#     accelerator = Accelerator(
#   File "/usr/local/lib/python3.10/dist-packages/accelerate/accelerator.py", line 376, in __init__
#     self.state = AcceleratorState(
#   File "/usr/local/lib/python3.10/dist-packages/accelerate/state.py", line 850, in __init__
#     PartialState(cpu, **kwargs)
#   File "/usr/local/lib/python3.10/dist-packages/accelerate/state.py", line 212, in __init__
#     torch.distributed.init_process_group(backend=self.backend, **kwargs)
#   File "/usr/local/lib/python3.10/dist-packages/torch/distributed/c10d_logger.py", line 75, in wrapper
#     return func(*args, **kwargs)
#   File "/usr/local/lib/python3.10/dist-packages/torch/distributed/c10d_logger.py", line 89, in wrapper
#     func_return = func(*args, **kwargs)
#   File "/usr/local/lib/python3.10/dist-packages/torch/distributed/distributed_c10d.py", line 1249, in init_process_group
#     store, rank, world_size = next(rendezvous_iterator)
#   File "/usr/local/lib/python3.10/dist-packages/torch/distributed/rendezvous.py", line 242, in _env_rendezvous_handler
#     master_addr = _get_env_or_raise("MASTER_ADDR")
#   File "/usr/local/lib/python3.10/dist-packages/torch/distributed/rendezvous.py", line 219, in _get_env_or_raise
#     raise _env_error(env_var)
# ValueError: Error initializing torch.distributed using env:// rendezvous: environment variable MASTER_ADDR expected, but not set
# Traceback (most recent call last):
#   File "/usr/local/bin/accelerate", line 8, in <module>
#     sys.exit(main())
#   File "/usr/local/lib/python3.10/dist-packages/accelerate/commands/accelerate_cli.py", line 48, in main
#     args.func(args)
#   File "/usr/local/lib/python3.10/dist-packages/accelerate/commands/launch.py", line 1097, in launch_command
#     simple_launcher(args)
#   File "/usr/local/lib/python3.10/dist-packages/accelerate/commands/launch.py", line 703, in simple_launcher
#     raise subprocess.CalledProcessError(returncode=process.returncode, cmd=cmd)
# subprocess.CalledProcessError: Command '['/usr/bin/python', 'train_text_to_image.py', '--pretrained_model_name_or_path=CompVis/stable-diffusion-v1-4', '--dataset_name=lambdalabs/naruto-blip-captions', '--use_ema', '--resolution=512', '--center_crop', '--random_flip', '--train_batch_size=1', '--gradient_accumulation_steps=4', '--gradient_checkpointing', '--max_train_steps=15000', '--learning_rate=1e-05', '--max_grad_norm=1', '--lr_scheduler=constant', '--lr_warmup_steps=0', '--output_dir=sd-pokemon-model2']' returned non-zero exit status 1.
