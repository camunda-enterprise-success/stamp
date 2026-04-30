package com.example.camunda.c8jobworker.scheduler;

import io.camunda.client.CamundaClient;
import io.camunda.client.api.response.ProcessInstanceEvent;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.YearMonth;
import java.time.format.DateTimeFormatter;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

@Slf4j
@Component
public class ProcessInstanceCreationScheduler {

    @Autowired // Spring has changed the need for Autowired but Emma doesn't understand it yet
    public CamundaClient camundaClient;

    @Scheduled(fixedRate = 1000L)
    public void startUserTaskProcesses() {
        Map<String, Object> varMap = generateVarMap();

        ProcessInstanceEvent event =
            camundaClient
                    .newCreateInstanceCommand()
                    .bpmnProcessId("paymentProcess")
                    .latestVersion()
                    .variables(varMap)
                    .send()
                    .join(); // needed to ensure we have the result to log in the next line. Otherwise you can avoid the .join()

        log.info(
                "Started instance: definitionKey={}, bpmnProcessId={}, version={}, processInstanceKey={}",
                event.getProcessDefinitionKey(),
                event.getBpmnProcessId(),
                event.getVersion(),
                event.getProcessInstanceKey()
        );
    }

    private Map<String, Object> generateVarMap(){
        final String CUSTOMER_PREFIX = "cust";
        final int randomId = ThreadLocalRandom.current().nextInt(0, 101);
        final int randomOrderTotal = ThreadLocalRandom.current().nextInt(0, 201);
        final String randomCreditCardNumber = String.valueOf(ThreadLocalRandom.current().nextInt(10_000_000, 100_000_000));
        final String randomCVC = String.valueOf(ThreadLocalRandom.current().nextInt(100, 999));
        final String randomDate = randomBeforeOrAfterNow();

        Map<String, Object> varMap = new HashMap<>();
        varMap.put("customerId", CUSTOMER_PREFIX + randomId);
        varMap.put("orderTotal", randomOrderTotal);
        varMap.put("cardNumber", randomCreditCardNumber);
        varMap.put("cvc",randomCVC );
        varMap.put("expiryDate", randomDate);

        return varMap;
    }

    private String randomBeforeOrAfterNow() {
        YearMonth now = YearMonth.now();

        // random choice: before (true) or after (false)
        boolean before = ThreadLocalRandom.current().nextBoolean();

        // random offset between 1 and 60 months (1–5 years)
        int offsetMonths = ThreadLocalRandom.current().nextInt(1, 61);

        YearMonth ym = before ? now.minusMonths(offsetMonths) : now.plusMonths(offsetMonths);
        return ym.format(DateTimeFormatter.ofPattern("MM/yyyy"));
    }

}
