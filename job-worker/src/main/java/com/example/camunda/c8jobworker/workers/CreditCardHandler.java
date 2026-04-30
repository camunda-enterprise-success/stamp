package com.example.camunda.c8jobworker.workers;

import com.example.camunda.c8jobworker.services.CreditCardExpiredException;
import com.example.camunda.c8jobworker.services.CreditCardService;
import io.camunda.client.CamundaClient;
import io.camunda.client.annotation.JobWorker;

import java.time.Duration;
import java.util.Map;

import io.camunda.client.api.response.ActivatedJob;
import io.camunda.client.api.worker.JobClient;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class CreditCardHandler {

    private final CreditCardService creditCardService;
    private final CamundaClient camundaClient;

    public CreditCardHandler(CreditCardService creditCardService, CamundaClient camundaClient) {
        this.creditCardService = creditCardService;
        this.camundaClient = camundaClient;
    }

    @JobWorker(type = "creditCardCharging", autoComplete = true)
    public void handle(JobClient client, ActivatedJob job) {
        log.info("Handling credit card payment for process instance {}", job.getProcessInstanceKey());

        try {
            Map<String, Object> variables = job.getVariablesAsMap();
            String cardNumber = (String) variables.get("cardNumber");
            String cvc = (String) variables.get("cvc");
            String expiryDate = (String) variables.get("expiryDate");
            Double amount = Double.valueOf(variables.get("openAmount").toString());
            creditCardService.chargeAmount(cardNumber, cvc, expiryDate, amount);
        } catch (CreditCardExpiredException e) {
            log.warn("Error message for instance {}, job {}: {}",job.getProcessInstanceKey(), job.getKey(), e.getMessage(), e);
            client
                    .newThrowErrorCommand(job)
                    .errorCode("creditCardError")
                    .errorMessage(e.getLocalizedMessage())
                    .variables(Map.of("errorMessage", e.getLocalizedMessage()))
                    .send();
        }
    }
}