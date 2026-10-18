#!/usr/bin/env python3
"""Nucleus segmentation baseline: small U-Net -> foreground probability -> connected components.

Contract with eval/run_eval.py (do not change the command-line interface):
    python train.py --train TRAIN.npz --predict PRED.npz --out OUTDIR [hyperparameters]
Train on TRAIN.npz (images uint8 (N,H,W), labels int16 instance maps), then write
OUTDIR/pred.npy: an int32 (M,H,W) instance-label map for every image in PRED.npz, same order.
"""
import argparse
import os
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from scipy import ndimage as ndi


def get_args():
    p = argparse.ArgumentParser()
    p.add_argument("--train", required=True)
    p.add_argument("--predict", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--lr", type=float, default=1e-3)
    p.add_argument("--batch", type=int, default=8)
    p.add_argument("--epochs", type=int, default=40)
    p.add_argument("--base", type=int, default=16)
    p.add_argument("--thresh", type=float, default=0.5)
    p.add_argument("--seed", type=int, default=0)
    return p.parse_args()


def normalize(x):
    """uint8 (N,H,W) -> float32 in [0,1], per-image percentile stretch."""
    x = x.astype(np.float32)
    out = np.empty_like(x)
    for i, im in enumerate(x):
        lo, hi = np.percentile(im, [1, 99.5])
        out[i] = np.clip((im - lo) / max(hi - lo, 1e-3), 0, 1)
    return out


def block(i, o):
    return nn.Sequential(
        nn.Conv2d(i, o, 3, padding=1), nn.BatchNorm2d(o), nn.ReLU(True),
        nn.Conv2d(o, o, 3, padding=1), nn.BatchNorm2d(o), nn.ReLU(True),
    )


class UNet(nn.Module):
    def __init__(self, base=16, out=1):
        super().__init__()
        c = [base, base * 2, base * 4]
        self.e1, self.e2, self.e3 = block(1, c[0]), block(c[0], c[1]), block(c[1], c[2])
        self.u2, self.d2 = nn.ConvTranspose2d(c[2], c[1], 2, stride=2), block(c[2], c[1])
        self.u1, self.d1 = nn.ConvTranspose2d(c[1], c[0], 2, stride=2), block(c[1], c[0])
        self.head = nn.Conv2d(c[0], out, 1)

    def forward(self, x):
        e1 = self.e1(x)
        e2 = self.e2(F.max_pool2d(e1, 2))
        e3 = self.e3(F.max_pool2d(e2, 2))
        d2 = self.d2(torch.cat([self.u2(e3), e2], 1))
        d1 = self.d1(torch.cat([self.u1(d2), e1], 1))
        return self.head(d1)


def augment(x, y):
    """Random flips / 90-degree rotations, same transform for image and target."""
    if np.random.rand() < 0.5:
        x, y = x.flip(-1), y.flip(-1)
    if np.random.rand() < 0.5:
        x, y = x.flip(-2), y.flip(-2)
    k = np.random.randint(4)
    return torch.rot90(x, k, (-2, -1)), torch.rot90(y, k, (-2, -1))


def main():
    a = get_args()
    np.random.seed(a.seed)
    torch.manual_seed(a.seed)
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    t0 = time.time()

    tr = np.load(a.train)
    X = torch.from_numpy(normalize(tr["images"]))[:, None].to(dev)
    Y = torch.from_numpy((tr["labels"] > 0).astype(np.float32))[:, None].to(dev)

    net = UNet(a.base).to(dev)
    opt = torch.optim.Adam(net.parameters(), lr=a.lr)
    n = len(X)
    for ep in range(a.epochs):
        net.train()
        perm = torch.randperm(n, device=dev)
        total = 0.0
        for i in range(0, n, a.batch):
            idx = perm[i:i + a.batch]
            xb, yb = augment(X[idx], Y[idx])
            loss = F.binary_cross_entropy_with_logits(net(xb), yb)
            opt.zero_grad()
            loss.backward()
            opt.step()
            total += loss.item() * len(idx)
        if ep % 10 == 0 or ep == a.epochs - 1:
            print(f"epoch {ep + 1}/{a.epochs} loss {total / n:.4f} t={time.time() - t0:.0f}s", flush=True)

    net.eval()
    pr = np.load(a.predict)
    P = torch.from_numpy(normalize(pr["images"]))[:, None].to(dev)
    preds = []
    with torch.no_grad():
        for i in range(0, len(P), 16):
            prob = torch.sigmoid(net(P[i:i + 16]))[:, 0].cpu().numpy()
            for m in prob:
                lab, _ = ndi.label(m > a.thresh)
                preds.append(lab.astype(np.int32))
    os.makedirs(a.out, exist_ok=True)
    np.save(os.path.join(a.out, "pred.npy"), np.stack(preds))
    print(f"done in {time.time() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    main()
