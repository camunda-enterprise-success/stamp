package com.example.camunda.c8jobworker.services;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class CustomerService {
    
    /** The customer credit are the last digits of the customer id */
    private Pattern pattern = Pattern.compile("(.*?)(\\d*)");

    /**
     * Deduct the credit for the given customer and the given amount
     *
     * @param customerId
     * @param amount
     * @param credit
     * @return the open order amount
     */
    public Double deductCredit(String customerId, Double amount, Double credit) {
        // Double credit = getCustomerCredit(customerId);
        double openAmount;
        double deductedCredit;
        if (credit > amount) {
            deductedCredit = amount;
            openAmount = 0.0;
        } else {
            openAmount = amount - credit;
            deductedCredit = credit;
        }
        log.info("charged {} from the credit, open amount is {}", deductedCredit, openAmount);
        return openAmount;
    }

    /**
     * Get the current customer credit
     *
     * @param customerId
     * @return the current credit of the given customer
     */
    public Double getCustomerCredit(String customerId) {
        double credit = 0.0;
        Matcher matcher = pattern.matcher(customerId);

        if (matcher.matches() && matcher.group(2) != null && matcher.group(2).length() > 0) {
            credit = Double.valueOf(matcher.group(2));
        } else {
            throw new RuntimeException("The customer ID doesn't end with a number");
        }

        log.info("customer {} has credit of {}", customerId, credit);

        return credit;
    }
}