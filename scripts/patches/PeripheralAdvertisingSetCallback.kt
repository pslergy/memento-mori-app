package dev.steenbakker.flutter_ble_peripheral.callbacks

import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.BluetoothLeAdvertiser
import android.os.Build
import androidx.annotation.RequiresApi
import dev.steenbakker.flutter_ble_peripheral.handlers.StateChangedHandler
import dev.steenbakker.flutter_ble_peripheral.models.PeripheralState
import io.flutter.Log
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean


@RequiresApi(Build.VERSION_CODES.O)
class PeripheralAdvertisingSetCallback(private val result: MethodChannel.Result, private val stateChangedHandler: StateChangedHandler): AdvertisingSetCallback() {
    /**
     * Callback triggered in response to {@link BluetoothLeAdvertiser#startAdvertisingSet}
     * indicating result of the operation. If status is ADVERTISE_SUCCESS, then advertisingSet
     * contains the started set and it is advertising. If error occurred, advertisingSet is
     * null, and status will be set to proper error code.
     *
     * @param advertisingSet The advertising set that was started or null if error.
     * @param txPower tx power that will be used for this set.
     * @param status Status of the operation.
     */

    private val replySent = AtomicBoolean(false)

    override fun onAdvertisingSetStarted(
        advertisingSet: AdvertisingSet?,
        txPower: Int,
        status: Int
    ) {
        Log.i(
            "FlutterBlePeripheral",
            "onAdvertisingSetStarted() set=$advertisingSet txPower=$txPower status=$status"
        )

        // BLE state machine — может дергаться сколько угодно
        when (status) {
            ADVERTISE_SUCCESS,
            ADVERTISE_FAILED_ALREADY_STARTED -> {
                stateChangedHandler.publishPeripheralState(PeripheralState.advertising)
            }

            ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> {
                stateChangedHandler.publishPeripheralState(PeripheralState.unsupported)
            }

            ADVERTISE_FAILED_INTERNAL_ERROR,
            ADVERTISE_FAILED_TOO_MANY_ADVERTISERS,
            ADVERTISE_FAILED_DATA_TOO_LARGE -> {
                stateChangedHandler.publishPeripheralState(PeripheralState.idle)
            }

            else -> {
                stateChangedHandler.publishPeripheralState(PeripheralState.unknown)
            }
        }

        // 🔒 Flutter reply — строго один раз (atomic, thread-safe)
        if (!replySent.compareAndSet(false, true)) {
            Log.w("FlutterBlePeripheral", "Reply already sent, ignoring duplicate callback")
            return
        }

        Handler(Looper.getMainLooper()).post {
            try {
                if (status == ADVERTISE_SUCCESS || status == ADVERTISE_FAILED_ALREADY_STARTED) {
                    result.success(0)
                } else {
                    result.error(
                        status.toString(),
                        "Advertising failed with status=$status",
                        "startAdvertisingSet"
                    )
                }
            } catch (e: IllegalStateException) {
                Log.e("FlutterBlePeripheral", "MethodChannel reply crash avoided", e)
            }
        }
    }


    /**
     * Callback triggered in response to [BluetoothLeAdvertiser.stopAdvertisingSet]
     * indicating advertising set is stopped.
     *
     * @param advertisingSet The advertising set.
     */
    override fun onAdvertisingSetStopped(advertisingSet: AdvertisingSet?) {
        Log.i("FlutterBlePeripheral", "onAdvertisingSetStopped() status: $advertisingSet")
        super.onAdvertisingSetStopped(advertisingSet)
        stateChangedHandler.publishPeripheralState(PeripheralState.idle)
    }

    /**
     * Callback triggered in response to [BluetoothLeAdvertiser.startAdvertisingSet]
     * indicating result of the operation. If status is ADVERTISE_SUCCESS, then advertising set is
     * advertising.
     *
     * @param advertisingSet The advertising set.
     * @param status Status of the operation.
     */
    override fun onAdvertisingEnabled(
            advertisingSet: AdvertisingSet?,
            enable: Boolean,
            status: Int
    ) {
        Log.i("FlutterBlePeripheral", "onAdvertisingEnabled() status: $advertisingSet, enable $enable, status $status")
        super.onAdvertisingEnabled(advertisingSet, enable, status)
        stateChangedHandler.publishPeripheralState(PeripheralState.advertising)
    }

    /**
     * Callback triggered in response to [AdvertisingSet.setAdvertisingData] indicating
     * result of the operation. If status is ADVERTISE_SUCCESS, then data was changed.
     *
     * @param advertisingSet The advertising set.
     * @param status Status of the operation.
     */
    override fun onAdvertisingDataSet(advertisingSet: AdvertisingSet?, status: Int) {
        Log.i("FlutterBlePeripheral", "onAdvertisingDataSet() status: $advertisingSet, status $status")
        super.onAdvertisingDataSet(advertisingSet, status)
        stateChangedHandler.publishPeripheralState(PeripheralState.advertising)
    }

    /**
     * Callback triggered in response to [AdvertisingSet.setAdvertisingData] indicating
     * result of the operation.
     *
     * @param advertisingSet The advertising set.
     * @param status Status of the operation.
     */
    override fun onScanResponseDataSet(advertisingSet: AdvertisingSet?, status: Int) {
        Log.i("FlutterBlePeripheral", "onScanResponseDataSet() status: $advertisingSet, status $status")
        super.onAdvertisingDataSet(advertisingSet, status)
        stateChangedHandler.publishPeripheralState(PeripheralState.advertising)
    }

    /**
     * Callback triggered in response to [AdvertisingSet.setAdvertisingParameters]
     * indicating result of the operation.
     *
     * @param advertisingSet The advertising set.
     * @param txPower tx power that will be used for this set.
     * @param status Status of the operation.
     */
    override fun onAdvertisingParametersUpdated(
            advertisingSet: AdvertisingSet?,
            txPower: Int, status: Int
    ) {
        Log.i("FlutterBlePeripheral", "onAdvertisingParametersUpdated() status: $advertisingSet, txPOWER $txPower, status $status")
    }

    /**
     * Callback triggered in response to [AdvertisingSet.setPeriodicAdvertisingParameters]
     * indicating result of the operation.
     *
     * @param advertisingSet The advertising set.
     * @param status Status of the operation.
     */
    override fun onPeriodicAdvertisingParametersUpdated(
            advertisingSet: AdvertisingSet?,
            status: Int
    ) {
        Log.i("FlutterBlePeripheral", "onPeriodicAdvertisingParametersUpdated() status: $advertisingSet, status $status")
    }

    /**
     * Callback triggered in response to [AdvertisingSet.setPeriodicAdvertisingData]
     * indicating result of the operation.
     *
     * @param advertisingSet The advertising set.
     * @param status Status of the operation.
     */
    override fun onPeriodicAdvertisingDataSet(
            advertisingSet: AdvertisingSet?,
            status: Int
    ) {
        Log.i("FlutterBlePeripheral", "onPeriodicAdvertisingDataSet() status: $advertisingSet, status $status")
    }

    /**
     * Callback triggered in response to [AdvertisingSet.setPeriodicAdvertisingEnabled]
     * indicating result of the operation.
     *
     * @param advertisingSet The advertising set.
     * @param status Status of the operation.
     */
    override fun onPeriodicAdvertisingEnabled(
            advertisingSet: AdvertisingSet?,
            enable: Boolean,
            status: Int
    ) {
        Log.i("FlutterBlePeripheral", "onPeriodicAdvertisingEnabled() status: $advertisingSet, enable $enable, status $status")
    }
}
