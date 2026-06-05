# -----------------------------------------------------------------------------
# gp2 StorageClass default annotation
#
# EKS auto-creates a `gp2` StorageClass but does NOT set it as default.
# Mark it as default so PVCs without an explicit storageClassName bind to gp2.
#
# We use kubernetes_annotations (not kubernetes_storage_class) because the
# gp2 StorageClass object itself is owned by EKS, not by terraform. We just
# add/manage one annotation on it.
#
# `force = true` lets terraform overwrite the annotation even if another
# controller had tried to manage it.
# -----------------------------------------------------------------------------

resource "kubernetes_annotations" "gp2_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "true"
  }

  force = true

  # gp2 is created as part of cluster bootstrap, so wait for the cluster
  # itself (the node group dependency covers data-plane readiness too).
  depends_on = [
    aws_eks_cluster.this,
    aws_eks_node_group.this,
  ]
}
