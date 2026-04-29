package com.example.camunda.c8jobworker.workers;

import com.example.camunda.c8jobworker.services.CustomerService;
import io.camunda.client.annotation.JobWorker;

import java.util.Map;

import io.camunda.client.api.response.ActivatedJob;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class CustomerCreditHandler {

    private final CustomerService customerService;

    public CustomerCreditHandler(CustomerService customerService) {
        this.customerService = customerService;
    }

    @JobWorker(type = "customerCreditHandling")
    public Map<String, Object> handle(ActivatedJob job) {
        log.info("Handling customer credit for process instance {}", job.getProcessInstanceKey());

        Map<String, Object> variables = job.getVariablesAsMap();
        String customerId = (String) variables.get("customerId");
        Double amount = Double.valueOf(variables.get("orderTotal").toString());

        Double customerCredit = customerService.getCustomerCredit(customerId);
        Double remainingAmount = customerService.deductCredit(customerId, amount, customerCredit);

        return Map.of("customerCredit", customerCredit, "remainingAmount", remainingAmount);
    }
}