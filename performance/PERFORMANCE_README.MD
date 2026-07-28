```bash
k create ns camunda
kubens camunda
```

```bash
kubectl create secret generic jens-keycloak-client-secrets \
--from-literal=oc-secret="gHSCIDc7liPeFxMlBuouPK310N6oPVQj" \
--from-literal=optimize-secret="NiQEzoKr7F2dyzvH16BmPZ1EDg3HND4w" \
--from-literal=mgmt-identity-secret="LImeBg8EjtyUYYwOo4CMiwIX3QRsxYg3" \
--from-literal=console-secret="5S1Qsb813Tin0uPTHPOxRGS6l8UYQupK" \
-n camunda
```

```bash
kubectl create secret generic camunda-credentials \
--from-literal=identity-postgresql-admin-password="jens" \
--from-literal=identity-postgresql-user-password="jens" \
-n camunda
```

```bash
helm upgrade --install \
--create-namespace \
camunda camunda-platform \
--repo https://helm.camunda.io \
--version 14.1.0 \
--namespace camunda \
-f 8.9-values_V3.yaml
```

```bash 
kubectl create configmap models --from-file=CamundaProcess.bpmn=./BenchmarkProcess.bpmn
kubectl create configmap payload --from-file=./payload.json
kubectl apply -f ./zbctl-deploy-job-with-auth.yaml
kubectl apply -f ./benchmark.yaml
```







DEBUG STUFF

```bash
curl -s -X POST https://keycloak.consulting-sandbox.camunda.cloud/realms/jens-keycloak-as-oidc/protocol/openid-connect/token \
    -d "grant_type=password" \
    -d "client_id=oc-client" \
    -d "client_secret=gHSCIDc7liPeFxMlBuouPK310N6oPVQj" \
    -d "username=jens-admin" \
    -d "password=jens-admin" \
    -d "scope=openid" | jq -r .access_token)
```


```bash
curl -s -X POST https://keycloak.consulting-sandbox.camunda.cloud/realms/jens-keycloak-as-oidc/protocol/openid-connect/token \
    -d "grant_type=password" \
    -d "client_id=mgmt-identity-client" \
    -d "client_secret=LImeBg8EjtyUYYwOo4CMiwIX3QRsxYg3" \
    -d "username=jens-admin" \
    -d "password=jens-admin" \
    -d "scope=openid" | jq -r .access_token)
```