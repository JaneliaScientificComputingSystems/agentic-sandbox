#!/usr/bin/env python3
"""Download BBBC038 (2018 Data Science Bowl, stage 1 train) and pack the grayscale 256x256
fluorescence-nuclei images into train / val / test .npz files.

Run on any machine with internet, in a venv that has numpy and pillow:
    python3 -m venv hv && hv/bin/pip install numpy pillow
    hv/bin/python prepare_data.py OUTDIR
Writes OUTDIR/train.npz (200 images), val.npz (64), test.npz (70). Each file holds
images uint8 (N,256,256), labels int16 instance maps (0 = background), ids (image ids).
"""
import os
import sys
import urllib.request
import zipfile

import numpy as np
from PIL import Image

URL = "https://data.broadinstitute.org/bbbc/BBBC038/stage1_train.zip"
out = sys.argv[1]
raw = os.path.join(out, "raw")
os.makedirs(raw, exist_ok=True)
zpath = os.path.join(raw, "stage1_train.zip")
if not os.path.exists(zpath):
    urllib.request.urlretrieve(URL, zpath)          # about 83 MB
with zipfile.ZipFile(zpath) as z:
    z.extractall(os.path.join(raw, "x"))
root = os.path.join(raw, "x")

keep = []
for d in sorted(os.listdir(root)):
    im = np.array(Image.open(f"{root}/{d}/images/{d}.png"))
    if im.shape[:2] != (256, 256) or im.ndim != 3:
        continue
    rgb = im[..., :3].astype(int)
    gray = (np.abs(rgb[..., 0] - rgb[..., 1]) <= 2).all() and (np.abs(rgb[..., 0] - rgb[..., 2]) <= 2).all()
    if gray and rgb.mean() < 60:                      # grayscale, dark background = fluorescence
        keep.append(d)
print("kept", len(keep), "images")                    # 334 expected

rng = np.random.RandomState(20261017)
ids = [keep[i] for i in rng.permutation(len(keep))]
split = {"train": ids[:200], "val": ids[200:264], "test": ids[264:]}
for name, lst in split.items():
    X, Y = [], []
    for d in lst:
        X.append(np.array(Image.open(f"{root}/{d}/images/{d}.png"))[..., 0])
        lab = np.zeros(X[-1].shape, np.int16)
        for k, m in enumerate(sorted(os.listdir(f"{root}/{d}/masks")), 1):
            lab[np.array(Image.open(f"{root}/{d}/masks/{m}")) > 0] = k
        Y.append(lab)
    np.savez_compressed(os.path.join(out, f"{name}.npz"), images=np.stack(X), labels=np.stack(Y), ids=np.array(lst))
    print(name, len(lst))
