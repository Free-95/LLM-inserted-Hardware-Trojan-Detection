import torch
dataset = torch.load("detection/graphs/dataset.pt", weights_only=False)

# 1. Basic counts
print(f"Total graphs: {len(dataset)}")
print(f"Clean: {sum(1 for d in dataset if d.y.item() == 0)}")
print(f"Infected: {sum(1 for d in dataset if d.y.item() == 1)}")

# 2. Node feature sanity — every row should sum to exactly 2.0 or more
# (1.0 from the one-hot + at least some of the binary features)
d = dataset[0]
print(f"Feature dim: {d.x.size(1)}")          # should be 40
print(f"Feature row sums (first 5): {d.x[:5].sum(dim=1).tolist()}")
print(f"Trojan nodes in first infected graph:")
inf = [d for d in dataset if d.y.item() == 1][0]
print(f"  {int(inf.node_y.sum())} / {inf.x.size(0)} nodes")
