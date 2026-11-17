package com.citaq;

import android.os.CoolingDevice;
import android.os.IThermalEventListener;
import android.os.IThermalService;
import android.os.IThermalStatusListener;
import android.os.ServiceManager;
import android.os.Temperature;
import java.util.ArrayList;
import java.util.List;

/**
 * Stand-in "thermalservice" for the PX5 / MTC Android 10 build on the Citaq H10-3.
 * The MTC SystemServer never starts ThermalManagerService, so PowerManager.getThermalService()
 * is null and current Google Play services crash (NPE in addThermalStatusListener).
 * This registers a do-nothing IThermalService: status always NONE, no temperatures, no throttling.
 * Run as root:  CLASSPATH=/data/citaq/thermalstub.jar app_process /system/bin com.citaq.ThermalStub
 */
public class ThermalStub extends IThermalService.Stub {
    public boolean registerThermalEventListener(IThermalEventListener l) { return true; }
    public boolean registerThermalEventListenerWithType(IThermalEventListener l, int t) { return true; }
    public boolean unregisterThermalEventListener(IThermalEventListener l) { return true; }
    public List<Temperature> getCurrentTemperatures() { return new ArrayList<Temperature>(); }
    public List<Temperature> getCurrentTemperaturesWithType(int t) { return new ArrayList<Temperature>(); }
    public boolean registerThermalStatusListener(IThermalStatusListener l) { return true; }
    public boolean unregisterThermalStatusListener(IThermalStatusListener l) { return true; }
    public int getCurrentThermalStatus() { return 0; }   // THERMAL_STATUS_NONE
    public List<CoolingDevice> getCurrentCoolingDevices() { return new ArrayList<CoolingDevice>(); }
    public List<CoolingDevice> getCurrentCoolingDevicesWithType(int t) { return new ArrayList<CoolingDevice>(); }

    public static void main(String[] args) throws Exception {
        if (ServiceManager.getService("thermalservice") != null) {
            System.out.println("thermalservice already registered - nothing to do");
            return;
        }
        ServiceManager.addService("thermalservice", new ThermalStub());
        System.out.println("thermalservice stub registered");
        Object o = new Object();
        synchronized (o) { while (true) o.wait(); }   // binder threads serve calls
    }
}
