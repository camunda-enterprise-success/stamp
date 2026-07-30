### 1. Create ConfigMaps and Deploy Process
```bash
kubens camunda
kubectl create configmap models --from-file=CamundaProcess.bpmn=./BenchmarkProcess.bpmn
kubectl create configmap payload --from-file=./payload.json
kubectl apply -f ./zbctl-deploy-job.yaml
kubectl apply -f ./benchmark.yaml
```


# Other files in this directory
- `../benchmarking/` — a load-testing example (BPMN + zbctl job). See `../benchmarking/BENCHMARK_README.MD`. Uses the same `benchmark-client` created in step 05.
