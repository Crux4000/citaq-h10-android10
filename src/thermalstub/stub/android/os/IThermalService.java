package android.os;
import java.util.List;
/** Android 10 (API 29) IThermalService AIDL interface, compile-time stand-in. */
public interface IThermalService extends IInterface {
    boolean registerThermalEventListener(IThermalEventListener l) throws RemoteException;
    boolean registerThermalEventListenerWithType(IThermalEventListener l, int type) throws RemoteException;
    boolean unregisterThermalEventListener(IThermalEventListener l) throws RemoteException;
    List<Temperature> getCurrentTemperatures() throws RemoteException;
    List<Temperature> getCurrentTemperaturesWithType(int type) throws RemoteException;
    boolean registerThermalStatusListener(IThermalStatusListener l) throws RemoteException;
    boolean unregisterThermalStatusListener(IThermalStatusListener l) throws RemoteException;
    int getCurrentThermalStatus() throws RemoteException;
    List<CoolingDevice> getCurrentCoolingDevices() throws RemoteException;
    List<CoolingDevice> getCurrentCoolingDevicesWithType(int type) throws RemoteException;
    abstract class Stub extends Binder implements IThermalService {
        public IBinder asBinder() { return this; }
    }
}
