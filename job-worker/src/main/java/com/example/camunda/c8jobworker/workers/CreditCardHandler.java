package com.example.camunda.c8jobworker.workers;

import com.example.camunda.c8jobworker.services.CreditCardExpiredException;
import com.example.camunda.c8jobworker.services.CreditCardService;
import io.camunda.client.annotation.JobWorker;
import io.camunda.zeebe.client.api.response.ActivatedJob;
import io.camunda.zeebe.client.api.worker.JobClient;
import java.util.Map;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class CreditCardHandler {

    private final CreditCardService creditCardService;

    public CreditCardHandler(CreditCardService creditCardService) {
        this.creditCardService = creditCardService;
    }

    @JobWorker(type = "creditCardCharging", autoComplete = false)
    public void handle(JobClient client, ActivatedJob job) {
        log.info("Handling credit card payment for process instance {}", job.getProcessInstanceKey());
        Map<String, Object> variables = job.getVariablesAsMap();
        String cardNumber = (String) variables.get("cardNumber");
        String cvc = (String) variables.get("cvc");
        String expiryDate = (String) variables.get("expiryDate");
        Double amount = Double.valueOf(variables.get("openAmount").toString());
        try {
            creditCardService.chargeAmount(cardNumber, cvc, expiryDate, amount);
            client.newCompleteCommand(job).send();
        } catch (CreditCardExpiredException e) {
            log.info("Credit card payment failed: {}", e.getLocalizedMessage());
            client
                    .newThrowErrorCommand(job)
                    .errorCode("creditCardError")
                    .errorMessage(e.getLocalizedMessage())
                    .variables(Map.of("errorMessage", e.getLocalizedMessage()))
                    .send();
        }
    }
}