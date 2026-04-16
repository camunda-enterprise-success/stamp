### 1. Create ConfigMaps and Deploy Process
```bash
kubens camunda
kubectl create configmap models --from-file=CamundaProcess.bpmn=./benchmarking/BenchmarkProcess.bpmn
kubectl create configmap payload --from-file=./benchmarking/payload.json
kubectl apply -f ./benchmarking/zbctl-deploy-job.yaml
kubectl apply -f ./benchmarking/benchmark.yaml
```