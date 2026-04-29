package com.example.camunda.c8jobworker.services;

import java.time.LocalDate;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

@Slf4j
@Component
public class CreditCardService {


    public void chargeAmount(String cardNumber, String cvc, String expiryDate, Double amount) {
        log.info(
                "charging card {} that expires on {} and has cvc {} with amount of {}",
                cardNumber,
                expiryDate,
                cvc,
                amount);
        if (!validateExpiryDate(expiryDate)) {
            String message = "Expiry date " + expiryDate + " is invalid";
            log.info("Error message: {}", message);
            throw new CreditCardExpiredException(message);
        }

        log.info("payment completed");
    }

    boolean validateExpiryDate(String expiryDate) {
        if (expiryDate.length() != 5) {
            return false;
        }
        try {
            int month = Integer.parseInt(expiryDate.substring(0, 2));
            int year = Integer.parseInt(expiryDate.substring(3, 5)) + 2000;
            LocalDate now = LocalDate.now();
            if (month < 1 || month > 12 || year < now.getYear()) {
                return false;
            }
            return year > now.getYear() || (year == now.getYear() && month >= now.getMonthValue());
        } catch (NumberFormatException | IndexOutOfBoundsException e) {
            return false;
        }
    }
}
