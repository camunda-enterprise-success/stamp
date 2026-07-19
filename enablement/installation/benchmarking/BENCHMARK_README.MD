### 1. Create ConfigMaps and Deploy Process
```bash
kubens camunda
kubectl create configmap models --from-file=CamundaProcess.bpmn=./BenchmarkProcess.bpmn
kubectl create configmap payload --from-file=./payload.json
kubectl apply -f ./zbctl-deploy-job.yaml
kubectl apply -f ./benchmark.yaml
```