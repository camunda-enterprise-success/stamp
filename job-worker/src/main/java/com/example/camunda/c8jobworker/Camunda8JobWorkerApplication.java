package com.example.camunda.c8jobworker;

import io.camunda.client.annotation.Deployment;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@Deployment(resources = {"classpath*:*.bpmn", "classpath*:*.dmn"})
@EnableScheduling // required for automated process instance creation
public class Camunda8JobWorkerApplication {

    public static void main(String[] args) {
        SpringApplication.run(Camunda8JobWorkerApplication.class, args);
    }
}