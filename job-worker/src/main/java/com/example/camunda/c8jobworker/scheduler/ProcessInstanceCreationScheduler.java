package com.example.camunda.c8jobworker.scheduler;

import io.camunda.client.CamundaClient;
import io.camunda.client.api.response.ProcessInstanceEvent;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class ProcessInstanceCreationScheduler {

    @Autowired // Spring has changed the need for Autowired but Emma doesn't understand it yet
    public CamundaClient camundaClient;

    @Scheduled(fixedRate = 1L)
    public void startUserTaskProcesses() {
        ProcessInstanceEvent event =
            camundaClient
                    .newCreateInstanceCommand()
                    .bpmnProcessId("Process_Payment_Sent")
                    .latestVersion()
                    .variable("foo", "bar")
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
}
