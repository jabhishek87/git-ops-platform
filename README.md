# git-ops-platform
Nova Deploy - The Git Ops Platform


### Tools Used
Docker
Kubectl
kind
helm




#### commands
kubectl port-forward svc/argocd-server -n argocd 8080:443

### Sync now
kubectl annotate application platform -n argocd argocd.argoproj.io/refresh=hard --overwrite

### validate
kubectl apply --dry-run=client -f platform/apps/
kubectl apply --dry-run=server -f platform/apps/
