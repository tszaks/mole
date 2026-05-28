package main

import (
	"math"
	"testing"
)

func TestParseSystemPowerJSON(t *testing.T) {
	raw := `{
  "SPPowerDataType" : [
    {
      "sppower_battery_health_info" : {
        "sppower_battery_cycle_count" : 4,
        "sppower_battery_health" : "Good",
        "sppower_battery_health_maximum_capacity" : "100\u00a0%"
      }
    }
  ]
}`

	health, cycles, capacity, ok := parseSystemPowerJSON(raw)

	if !ok {
		t.Fatal("expected battery health JSON to parse")
	}
	if health != "Good" {
		t.Fatalf("health = %q, want Good", health)
	}
	if cycles != 4 {
		t.Fatalf("cycles = %d, want 4", cycles)
	}
	if capacity != 100 {
		t.Fatalf("capacity = %d, want 100", capacity)
	}
}

func TestParseSystemPowerJSONRejectsInvalidPayload(t *testing.T) {
	_, _, _, ok := parseSystemPowerJSON(`{"SPPowerDataType":[{}]}`)
	if ok {
		t.Fatal("expected empty battery health JSON to be ignored")
	}
}

func TestParseSystemPowerText(t *testing.T) {
	nonBreakingSpace := string(rune(0x00a0))
	raw := "    Battery Information:\n\n" +
		"      Health Information:\n" +
		"          Cycle Count: 12\n" +
		"          Condition: Normal\n" +
		"          Maximum Capacity: 97" + nonBreakingSpace + "%\n"

	health, cycles, capacity := parseSystemPowerText(raw)

	if health != "Normal" {
		t.Fatalf("health = %q, want Normal", health)
	}
	if cycles != 12 {
		t.Fatalf("cycles = %d, want 12", cycles)
	}
	if capacity != 97 {
		t.Fatalf("capacity = %d, want 97", capacity)
	}
}

func TestMergeBatteryHealthDataPrefersAppleSmartBatteryCapacity(t *testing.T) {
	health, cycles, capacity := mergeBatteryHealthData("Good", 12, 97, 13, 100)

	if health != "Good" {
		t.Fatalf("health = %q, want Good", health)
	}
	if cycles != 13 {
		t.Fatalf("cycles = %d, want 13", cycles)
	}
	if capacity != 100 {
		t.Fatalf("capacity = %d, want 100", capacity)
	}
}

func TestParseAppleSmartBatteryHealth(t *testing.T) {
	out := `
  | |   "BatteryData" = {"MaxCapacity"=100,"DesignCapacity"=8579,"BatteryHealthMetric"=0}
  | |   "NominalChargeCapacity" = 7989
  | |   "MaxCapacity" = 100
  | |   "DesignCapacity" = 8579
  | |   "CycleCount" = 4
`

	cycles, capacity := parseAppleSmartBatteryHealth(out)

	if cycles != 4 {
		t.Fatalf("cycles = %d, want 4", cycles)
	}
	if capacity != 100 {
		t.Fatalf("capacity = %d, want 100", capacity)
	}
}

func TestParseAppleSmartBatteryHealthIgnoresRawMaxCapacity(t *testing.T) {
	out := `
  | |   "MaxCapacity" = 7745
  | |   "DesignCapacity" = 8579
  | |   "CycleCount" = 12
`

	cycles, capacity := parseAppleSmartBatteryHealth(out)

	if cycles != 12 {
		t.Fatalf("cycles = %d, want 12", cycles)
	}
	if capacity != 0 {
		t.Fatalf("capacity = %d, want 0", capacity)
	}
}

func TestParseAppleSmartBatteryThermalKeepsBatteryTemperatureOutOfCPUTemp(t *testing.T) {
	out := `
  | |   "Temperature" = 3055
  | |   "SystemPowerIn" = 19967
  | |   "BatteryPower" = 13654
  | |   "AdapterDetails" = {"Watts" = 96}
`

	thermal := parseAppleSmartBatteryThermal(out)

	if thermal.CPUTemp != 0 {
		t.Fatalf("expected cpu temp to stay unset, got %v", thermal.CPUTemp)
	}
	if math.Abs(thermal.BatteryTemp-30.55) > 0.001 {
		t.Fatalf("expected battery temp 30.55, got %v", thermal.BatteryTemp)
	}
	if math.Abs(thermal.SystemPower-19.967) > 0.001 {
		t.Fatalf("expected system power 19.967W, got %v", thermal.SystemPower)
	}
	if thermal.AdapterPower != 96 {
		t.Fatalf("expected adapter power 96W, got %v", thermal.AdapterPower)
	}
	if math.Abs(thermal.BatteryPower-13.654) > 0.001 {
		t.Fatalf("expected battery power 13.654W, got %v", thermal.BatteryPower)
	}
}

func TestParseAppleSmartBatteryThermalParsesTwosComplementBatteryPower(t *testing.T) {
	out := `
  | |   "BatteryPower"=18446744073709539271
`

	thermal := parseAppleSmartBatteryThermal(out)

	if math.Abs(thermal.BatteryPower-(-12.345)) > 0.001 {
		t.Fatalf("expected battery power -12.345W, got %v", thermal.BatteryPower)
	}
}

func TestParseAppleSmartBatteryThermalDerivesBatteryWattsFromVoltageAndAmperage(t *testing.T) {
	out := `
  | |   "Voltage" = 12000
  | |   "InstantAmperage" = -1500
`

	thermal := parseAppleSmartBatteryThermal(out)

	if math.Abs(thermal.BatteryPower-18.0) > 0.001 {
		t.Fatalf("expected derived battery power 18W, got %v", thermal.BatteryPower)
	}
}

func TestParseAppleSmartBatteryThermalIgnoresRawAdapterWatts(t *testing.T) {
	out := `
  | |   "AppleRawAdapterDetails" = {"Watts" = 140}
  | |   "AdapterDetails" = {"Watts" = 96}
`

	thermal := parseAppleSmartBatteryThermal(out)

	if thermal.AdapterPower != 96 {
		t.Fatalf("expected normalized adapter power 96W, got %v", thermal.AdapterPower)
	}
}
