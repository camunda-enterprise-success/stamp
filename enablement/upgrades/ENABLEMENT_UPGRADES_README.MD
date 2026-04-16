Upgrading Camunda Installations falls under the TAM responsibilities and is something a TAM will encounter multiple with their customers. Therefore it's a skill to have.

- Easy: Single Zeebe Broker, Gateway and Operate with Basic Auth from 8.6 to 8.9
- Medium: 3 Zeebe Brokers, Gateway, Operate, Tasklist, Optimize with existing Keycloak from 8.6 to 8.9
- Hard: All components with existing Keycloak, with Multi-tenancy from 8.6 to 8.9


FAQ:

Q: Why from 8.6?
A: Understanding the upgrading procedure is a core skill, that needs to be understood. Extra minor versions == Extra training. It also provides some context, on how the platform evolved in the past, which is beneficial to know.
(I tried even earlier, but tooling before 8.6 was just the worst.)




---

## Easy

### Deploy Camunda 8.6
helm upgrade --install camunda camunda/camunda-platform -f ./easy/11.12.3-values-easy.yml --version 11.12.3 --create-namespace -n camunda

### Create some data
```bash
../utils/deploy-bpmn.sh
../utils/create-process-instances.sh
```

### Check in operate
login via demo/demo

### upgrade to Camunda 8.7
helm upgrade --install camunda camunda/camunda-platform -f ./easy/solution/12.8.4-values-easy.yml --version 12.8.4 --create-namespace -n camunda

### upgrade to Camunda 8.8
helm upgrade --install camunda camunda/camunda-platform -f ./easy/solution/13.7.0-values-easy.yml --version 13.7.0 --create-namespace -n camunda




## Medium

TODO: use something other than the consulting keycloak :')

### Deploy Camunda 8.7
helm upgrade --install camunda camunda/camunda-platform -f ./medium/12.8.4-values-medium.yml --version 12.8.4 --create-namespace -n camunda

### Create some data
```bash
../utils/deploy-bpmn.sh
../utils/create-process-instances.sh
```


### upgrade to Camunda 8.7
...

### upgrade to Camunda 8.8
...

