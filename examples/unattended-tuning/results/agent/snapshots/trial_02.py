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
from skimage.segmentation import watershed


def get_args():
    p = argparse.ArgumentParser()
    p.add_argument("--train", required=True)
    p.add_argument("--predict", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--lr", type=float, default=2e-3)
    p.add_argument("--batch", type=int, default=16)
    p.add_argument("--epochs", type=int, default=220)
    p.add_argument("--base", type=int, default=32)
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
    def __init__(self, base=16, out=2):
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


def augment(x, yfg, yb):
    """Random flips / 90-degree rotations + light intensity jitter."""
    if np.random.rand() < 0.5:
        x, yfg, yb = x.flip(-1), yfg.flip(-1), yb.flip(-1)
    if np.random.rand() < 0.5:
        x, yfg, yb = x.flip(-2), yfg.flip(-2), yb.flip(-2)
    k = np.random.randint(4)
    x, yfg, yb = (torch.rot90(x, k, (-2, -1)), torch.rot90(yfg, k, (-2, -1)),
                  torch.rot90(yb, k, (-2, -1)))
    g = 0.8 + 0.45 * np.random.rand()
    b = (np.random.rand() - 0.5) * 0.1
    return torch.clamp(x * g + b, 0, 1), yfg, yb


def boundary_targets(labels):
    """(N,H,W) instance labels -> (N,1,H,W) boundary map: each object's 1-px outline."""
    n = labels.shape[0]
    out = np.zeros((n, 1) + labels.shape[1:], np.float32)
    s3 = np.ones((3, 3), bool)
    for i in range(n):
        lab = labels[i]
        b = np.zeros(lab.shape, bool)
        for k in np.unique(lab):
            if k == 0:
                continue
            m = lab == k
            b |= m & ~ndi.binary_erosion(m, structure=s3, border_value=0)
        out[i, 0] = b
    return out


def dice_loss(logits, target):
    p = torch.sigmoid(logits)
    inter = (p * target).sum()
    return 1.0 - (2 * inter + 1.0) / (p.sum() + target.sum() + 1.0)


def tta_probs(net, x):
    """Average sigmoid probabilities over the 8 dihedral transforms."""
    pm = torch.zeros_like(x)
    pb = torch.zeros_like(x)
    for flip in (False, True):
        for k in range(4):
            xt = torch.flip(x, [-1]) if flip else x
            xt = torch.rot90(xt, k, (-2, -1))
            o = torch.sigmoid(net(xt))
            o = torch.rot90(o, -k, (-2, -1))
            if flip:
                o = torch.flip(o, [-1])
            pm += o[:, :1]
            pb += o[:, 1:]
    return (pm / 8.0)[:, 0].cpu().numpy(), (pb / 8.0)[:, 0].cpu().numpy()


def to_instances(pm, pb, fg_t=0.5, bnd_t=0.45, min_size=6):
    """Foreground/boundary probabilities -> instance labels via seeded watershed."""
    fg = pm > fg_t
    core = fg & (pb <= bnd_t)
    lab, _ = ndi.label(core)
    sizes = np.bincount(lab.ravel(), minlength=lab.max() + 1 if lab.size else 1)
    sizes[0] = min_size
    lab[(sizes < min_size)[lab]] = 0
    markers, nmark = ndi.label(lab > 0)
    if nmark == 0:
        out, _ = ndi.label(fg)
        return out.astype(np.int32)
    dist = ndi.distance_transform_edt(fg)
    cc, ncc = ndi.label(fg)
    nxt = markers.max() + 1
    for cid in range(1, ncc + 1):
        m = cc == cid
        if not markers[m].any():
            markers.flat[np.argmax(dist * m)] = nxt
            nxt += 1
    ws = watershed(-dist, markers, mask=fg)
    sizes = np.bincount(ws.ravel(), minlength=ws.max() + 1 if ws.size else 1)
    sizes[0] = min_size
    ws[(sizes < min_size)[ws]] = 0
    return ws.astype(np.int32)


def main():
    a = get_args()
    np.random.seed(a.seed)
    torch.manual_seed(a.seed)
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    t0 = time.time()

    tr = np.load(a.train)
    X = torch.from_numpy(normalize(tr["images"]))[:, None].to(dev)
    Y = torch.from_numpy((tr["labels"] > 0).astype(np.float32))[:, None].to(dev)
    B = torch.from_numpy(boundary_targets(tr["labels"])).to(dev)

    net = UNet(a.base, out=2).to(dev)
    opt = torch.optim.AdamW(net.parameters(), lr=a.lr, weight_decay=1e-5)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=a.epochs)
    posw = torch.tensor(5.0, device=dev)
    n = len(X)
    for ep in range(a.epochs):
        net.train()
        perm = torch.randperm(n, device=dev)
        total = 0.0
        for i in range(0, n, a.batch):
            idx = perm[i:i + a.batch]
            xb, yb, bb = augment(X[idx], Y[idx], B[idx])
            out = net(xb)
            loss = (F.binary_cross_entropy_with_logits(out[:, :1], yb)
                    + dice_loss(out[:, :1], yb)
                    + 2.0 * F.binary_cross_entropy_with_logits(out[:, 1:], bb, pos_weight=posw))
            opt.zero_grad()
            loss.backward()
            opt.step()
            total += loss.item() * len(idx)
        sched.step()
        if ep % 20 == 0 or ep == a.epochs - 1:
            print(f"epoch {ep + 1}/{a.epochs} loss {total / n:.4f} t={time.time() - t0:.0f}s", flush=True)

    net.eval()
    pr = np.load(a.predict)
    P = torch.from_numpy(normalize(pr["images"]))[:, None].to(dev)
    preds = []
    with torch.no_grad():
        for i in range(0, len(P), 16):
            pm, pb = tta_probs(net, P[i:i + 16])
            for j in range(len(pm)):
                preds.append(to_instances(pm[j], pb[j], fg_t=a.thresh))
    os.makedirs(a.out, exist_ok=True)
    np.save(os.path.join(a.out, "pred.npy"), np.stack(preds))
    print(f"done in {time.time() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    main()
