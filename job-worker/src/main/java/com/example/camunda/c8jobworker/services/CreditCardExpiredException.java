package com.example.camunda.c8jobworker.services;

public class CreditCardExpiredException extends RuntimeException {

    public CreditCardExpiredException(String message) {
        super(message);
    }
}