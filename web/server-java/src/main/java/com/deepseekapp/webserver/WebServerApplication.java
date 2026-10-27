package com.deepseekapp.webserver;

import com.deepseekapp.webserver.usb.UsbTunnel;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

import java.util.Arrays;

@SpringBootApplication
public class WebServerApplication {

    public static void main(String[] args) {
        if (Arrays.asList(args).contains("--usb")) {
            UsbTunnel.runFromArgs(args);
            return;
        }
        SpringApplication.run(WebServerApplication.class, args);
    }
}
