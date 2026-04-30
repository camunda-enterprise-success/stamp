package com.example.camunda.c8jobworker.workers;

import com.example.camunda.c8jobworker.services.CustomerService;
import io.camunda.client.CamundaClient;
import io.camunda.client.annotation.JobWorker;

import java.time.Duration;
import java.time.temporal.TemporalUnit;
import java.util.HashMap;
import java.util.Map;

import io.camunda.client.api.response.ActivatedJob;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class CustomerCreditHandler {

    private final CustomerService customerService;
    private final CamundaClient camundaClient;

    public CustomerCreditHandler(CustomerService customerService, CamundaClient camundaClient) {
        this.customerService = customerService;
        this.camundaClient = camundaClient;
    }

    @JobWorker(type = "customerCreditHandling")
    public Map<String, Object> handle(ActivatedJob job) {
        log.info("Handling customer credit for process instance {}", job.getProcessInstanceKey());
        Map<String, Object> varMap = new HashMap<>();
        try {
            Map<String, Object> variables = job.getVariablesAsMap();
            String customerId = (String) variables.get("customerId");
            Double amount = Double.valueOf(variables.get("orderTotal").toString());

            Double customerCredit = customerService.getCustomerCredit(customerId);
            Double remainingAmount = customerService.deductCredit(customerId, amount, customerCredit);

            varMap = Map.of("customerCredit", customerCredit, "remainingAmount", remainingAmount);
        } catch (Exception e) {
            log.error(e.getMessage(), e);
            camundaClient
                    .newFailCommand(job.getKey())
                    .retries(job.getRetries() - 1)
                    .retryBackoff(Duration.ofSeconds(10))
                    .errorMessage(e.getMessage())
                    .send();
        }
        return varMap;
    }
}