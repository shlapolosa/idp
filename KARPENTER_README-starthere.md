# Karpenter Installation and Usage Guide

## 🏁 Quick Start: Run Everything From One Script

All setup commands are consolidated in:

```
/Users/socrateshlapolosa/Development/testarch/idp/refresh-eksctl.sh
```

Run this script to install EKS with Karpenter support end-to-end.
To test after installation, run:

```
kubectl create deploy nginx --replicas=200 --image=nginx
```
initially you will see lots of pods that cannot be scheduled, then a claim gets created and eventually nodes are spun up to handle the pods.

afterwards to delete:

```
kubectl delete deploy nginx
```

---

## 📦 What Is Karpenter?

Karpenter is an **open-source autoscaler** for Kubernetes launched by AWS. It:

* Dynamically provisions nodes based on workload needs
* Uses Spot and On-Demand EC2 pricing models
* Eliminates manual node group management
* Leverages the Kubernetes **controller/operator** pattern

### Key Components:

* **NodePool**: declarative config for node policies
* **EC2NodeClass**: defines AWS-specific config like subnets, security groups, AMIs
* **NodeClaim**: ephemeral node request that triggers provisioning
* **Controller**: reconciles NodeClaims and manages provisioning logic

---

## 🛠️ Installation Notes & Lessons Learned

### ✅ Base Cluster Setup

The cluster is created using:

```bash
eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
...
EOF
```

> ❗ **Lesson:** The above config is **missing key add-ons**, which must be installed after the cluster is provisioned.

---

### ✅ Add-ons to Install Separately

After cluster creation, make sure to install:

* `vpc-cni`
* `coredns`
* `kube-proxy`
* `karpenter`
* (optional) `metrics-server`, `cluster-autoscaler` if needed

---

### ✅ NodePool Best Practices

Here’s an example of an **optimized NodePool**:

```yaml
requirements:
  - key: kubernetes.io/arch
    operator: In
    values: ["amd64"]
  - key: kubernetes.io/os
    operator: In
    values: ["linux"]
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["spot"]
  - key: karpenter.k8s.aws/instance-category
    operator: In
    values: ["c", "m", "r"]
  - key: karpenter.k8s.aws/instance-generation
    operator: Gt
    values: ["2"]
  - key: karpenter.k8s.aws/instance-size
    operator: In
    values: ["medium", "large"] # ✣️ Important to restrict large instances
```

> 💡 **Lesson:** Limiting `instance-size` avoids costly oversized nodes (e.g. `24xlarge`) that may be auto-selected on Spot.

---

### 📺 Highly Recommended Video

The following walkthrough is extremely helpful for installing Karpenter on an **already existing cluster**:

🎩 [Sharmio - Karpenter with Existing Cluster](https://www.youtube.com/watch?v=afCE5q3ZGyU&ab_channel=Sharmio)

---

### 🧪 Version Compatibility

> ⚠️ **Always check version compatibility between:**

* Kubernetes (`K8S_VERSION`)
* Karpenter release
* EKS AMI
* EC2NodeClass SSM Parameter

Reference: [Karpenter Compatibility Matrix](https://karpenter.sh/docs/)

---

### 🏠 `eksctl` Creates Multiple CloudFormation Stacks

**Order of creation:**

1. **VPC and networking** (if not already provided)
2. **EKS Control Plane**
3. **OIDC and IAM Roles**
4. **Managed Node Group(s)**
5. **Add-ons** (via `eksctl` or manually after)

> 🔍 You may not immediately see nodes until **all stacks are complete**.

---

### 🤍 Minimum Node Requirements

* You **must have at least 2 managed nodes**:

  * 1 for **Karpenter controller**
  * 1 for **workload pods**
* Karpenter **should NOT manage the node it runs on**

> 🧠 Good Practice: Don’t let Karpenter manage its own fate (e.g. it could terminate its own controller pod if misconfigured).

**Recommended minimum size:**

```yaml
instanceType: t3.small or t3.medium
```

---

## 🧠 Architecture Overview

### 👉 Kubernetes Operator Pattern

* Controllers run inside the cluster
* Reconcile custom resources: `NodeClaim`, `NodePool`, `EC2NodeClass`
* Make calls to AWS EC2 APIs to:

  * Discover instance types
  * Select optimal AMI (via SSM parameters)
  * Launch Spot or On-Demand instances

### 🔄 Consolidation

* Consolidates underutilized nodes
* Evicts pods and drains unused nodes

### 🛏️ EventBridge Integration

Karpenter integrates with **Amazon EventBridge** to:

* **Subscribe to Spot interruption notices**
* **React to EC2 instance lifecycle events** (e.g., termination, capacity rebalance)
* **Respond quickly to disruptions** to reschedule pods elsewhere

> EventBridge rules are automatically created by the Karpenter Helm chart when configured with the appropriate permissions.

### 📈 Simple Architecture Diagram

```
 +----------------+         +----------------+        +--------------------+
 |  Kubernetes    |<------->|  Karpenter      |<-----> |  AWS EC2 / Spot     |
 |  API Server    |         |  Controller     |        |  EventBridge + SSM |
 +----------------+         +----------------+        +--------------------+
        ^                          |
        |                          v
 +-------------+            +---------------+
 |  NodePools  |            |  NodeClaims   |
 +-------------+            +---------------+
```

---

## 🔄 Auto-Scaling Behavior

Karpenter reacts to:

* Unschedulable pods → provisions new nodes
* Idle or underutilized nodes → deprovisions
* Spot interruptions → reschedules pods

Supports **binpacking**, **zonal diversification**, and **cost optimization** out of the box.

---

## ✅ Final Checklist

| Item                                     | Status |
| ---------------------------------------- | ------ |
| `eksctl` script prepared                 | ✅      |
| Cluster created                          | ✅      |
| Add-ons installed                        | ✅      |
| `NodePool` optimized for spot + size     | ✅      |
| Versions checked for compatibility       | ✅      |
| Controller runs on separate managed node | ✅      |
| Karpenter behavior validated via logs    | ✅      |

---

## 📒 Resources

* [Karpenter Official Docs](https://karpenter.sh/docs/)
* [Karpenter GitHub](https://github.com/aws/karpenter)
* [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/)

---

## 📟 Summary of Key Lessons

1. `eksctl` does **not** install all needed add-ons — do it manually
2. Always set `instance-size` limits in NodePool
3. Maintain at least 2 managed nodes
4. Karpenter should not manage the node it runs on
5. Review CloudFormation stack events to monitor progress
6. Version compatibility is critical
7. Use Karpenter logs to trace instance provisioning decisions
8. EventBridge is key for spot awareness and reaction

---
