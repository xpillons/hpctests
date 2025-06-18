#!/bin/bash

cd ~

wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda-installer.sh
bash miniconda-installer.sh -b -p miniconda
source miniconda/bin/activate
conda create -n python38 python=3.8
conda activate python38

git clone https://github.com/huggingface/diffusers -b v0.29.2
cd diffusers
pip install .
pip install accelerate

cd examples/text_to_image
pip install -r requirements.txt
