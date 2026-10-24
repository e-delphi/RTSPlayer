//! Relógios: parede (ms Unix UTC) e monotônico, atrás de uma porta para teste
//! poder controlar o tempo.
//!
//! Também mora aqui a conversão de calendário (dia local, hora local). Sem
//! dependência de crate de data: o Windows dá o fuso pela API, e fora dele vale
//! UTC.

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::OnceLock;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

pub trait Clock: Send + Sync {
    /// ms Unix UTC.
    fn now_utc_ms(&self) -> i64;
    /// ms de um relógio que só anda para frente.
    fn monotonic_ms(&self) -> i64;
}

pub struct SystemClock;

fn mono_base() -> &'static Instant {
    static B: OnceLock<Instant> = OnceLock::new();
    B.get_or_init(Instant::now)
}

impl Clock for SystemClock {
    fn now_utc_ms(&self) -> i64 {
        unix_ms()
    }
    /// Nunca 0: em vários lugares 0 quer dizer "ainda não aconteceu" (o anel
    /// do ao vivo tomava a câmera que publicou no 1º ms por calada).
    fn monotonic_ms(&self) -> i64 {
        mono_base().elapsed().as_millis() as i64 + 1000
    }
}

pub fn unix_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

pub fn monotonic_ms() -> i64 {
    SystemClock.monotonic_ms()
}

/// Relógio de teste: anda só quando mandam.
#[derive(Default)]
pub struct ManualClock {
    pub wall: AtomicI64,
    pub mono: AtomicI64,
}

impl ManualClock {
    pub fn new(wall: i64) -> Self {
        Self { wall: AtomicI64::new(wall), mono: AtomicI64::new(0) }
    }
    pub fn advance(&self, ms: i64) {
        self.wall.fetch_add(ms, Ordering::SeqCst);
        self.mono.fetch_add(ms, Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now_utc_ms(&self) -> i64 {
        self.wall.load(Ordering::SeqCst)
    }
    fn monotonic_ms(&self) -> i64 {
        self.mono.load(Ordering::SeqCst)
    }
}

// ------------------------------------------------------------------ calendário

/// Data e hora de calendário, sem fuso embutido.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DateTime {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    pub millis: u32,
}

impl DateTime {
    /// `2026-08-16`
    pub fn date_str(&self) -> String {
        format!("{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
    /// `2026-08-16_18-37-57`, o carimbo do nome dos arquivos de gravação.
    pub fn file_stamp(&self) -> String {
        format!("{}_{:02}-{:02}-{:02}", self.date_str(), self.hour, self.minute, self.second)
    }
}

/// Dias desde 1970-01-01 → (ano, mês, dia). Algoritmo de Howard Hinnant.
pub fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    ((if m <= 2 { y + 1 } else { y }) as i32, m, d)
}

/// (ano, mês, dia) → dias desde 1970-01-01.
pub fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y as i64 - 1 } else { y as i64 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// ms Unix (já deslocado para o fuso desejado) → calendário.
pub fn datetime_from_ms(ms: i64) -> DateTime {
    let days = ms.div_euclid(86_400_000);
    let rem = ms.rem_euclid(86_400_000);
    let (year, month, day) = civil_from_days(days);
    DateTime {
        year,
        month,
        day,
        hour: (rem / 3_600_000) as u32,
        minute: (rem / 60_000 % 60) as u32,
        second: (rem / 1000 % 60) as u32,
        millis: (rem % 1000) as u32,
    }
}

/// Deslocamento do fuso local em ms (local = UTC + offset), no instante dado.
/// Consulta o sistema a cada chamada — o horário de verão muda o valor.
pub fn local_offset_ms(at_utc_ms: i64) -> i64 {
    if let Some(v) = FORCED_OFFSET.get() {
        return *v;
    }
    platform_offset_ms(at_utc_ms)
}

static FORCED_OFFSET: OnceLock<i64> = OnceLock::new();

/// Fixa o fuso (testes, ou `TZ` forçado na linha de comando). Só a primeira
/// chamada vale.
pub fn force_local_offset_ms(v: i64) {
    let _ = FORCED_OFFSET.set(v);
}

#[cfg(windows)]
fn platform_offset_ms(at_utc_ms: i64) -> i64 {
    // SystemTimeToTzSpecificLocalTime faz a conta com as regras do fuso,
    // inclusive horário de verão naquele instante.
    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct SystemTime {
        y: u16,
        m: u16,
        dow: u16,
        d: u16,
        h: u16,
        mi: u16,
        s: u16,
        ms: u16,
    }
    extern "system" {
        fn SystemTimeToTzSpecificLocalTime(tz: *const u8, utc: *const SystemTime, local: *mut SystemTime) -> i32;
    }
    let u = datetime_from_ms(at_utc_ms);
    let st = SystemTime {
        y: u.year as u16,
        m: u.month as u16,
        dow: 0,
        d: u.day as u16,
        h: u.hour as u16,
        mi: u.minute as u16,
        s: u.second as u16,
        ms: u.millis as u16,
    };
    let mut lt = SystemTime::default();
    // SAFETY: estruturas do layout SYSTEMTIME; tz nulo = fuso atual.
    let ok = unsafe { SystemTimeToTzSpecificLocalTime(std::ptr::null(), &st, &mut lt) };
    if ok == 0 {
        return 0;
    }
    let local = days_from_civil(lt.y as i32, lt.m as u32, lt.d as u32) * 86_400_000
        + lt.h as i64 * 3_600_000
        + lt.mi as i64 * 60_000
        + lt.s as i64 * 1000
        + lt.ms as i64;
    local - at_utc_ms
}

#[cfg(not(windows))]
fn platform_offset_ms(_at_utc_ms: i64) -> i64 {
    0
}

/// Agora, no fuso local.
pub fn local_now() -> DateTime {
    let u = unix_ms();
    datetime_from_ms(u + local_offset_ms(u))
}

/// Um instante UTC no calendário local.
pub fn local_from_utc_ms(utc_ms: i64) -> DateTime {
    datetime_from_ms(utc_ms + local_offset_ms(utc_ms))
}

/// O fuso como texto, `-03:00`.
pub fn utc_offset_str(at_utc_ms: i64) -> String {
    let off = local_offset_ms(at_utc_ms) / 60_000;
    let sinal = if off < 0 { '-' } else { '+' };
    let a = off.abs();
    format!("{sinal}{:02}:{:02}", a / 60, a % 60)
}

/// Começo do dia local (`YYYY-MM-DD`) em ms UTC. `None` se o texto não é data.
pub fn local_day_start_ms(day: &str) -> Option<i64> {
    let mut it = day.trim().split('-');
    let y: i32 = it.next()?.parse().ok()?;
    let m: u32 = it.next()?.parse().ok()?;
    let d: u32 = it.next()?.parse().ok()?;
    if it.next().is_some() || !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let local_midnight = days_from_civil(y, m, d) * 86_400_000;
    // O deslocamento depende do instante; uma correção basta (troca de horário
    // de verão perto da meia-noite pode errar uma hora, e o Delphi também).
    let guess = local_midnight - local_offset_ms(local_midnight);
    Some(local_midnight - local_offset_ms(guess))
}

/// O dia local de um instante UTC, `YYYY-MM-DD`.
pub fn local_day_of(utc_ms: i64) -> String {
    local_from_utc_ms(utc_ms).date_str()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calendario_ida_e_volta() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(days_from_civil(2026, 8, 16), 20681);
        for d in [-1000i64, 0, 10957, 20681, 50000] {
            let (y, m, dd) = civil_from_days(d);
            assert_eq!(days_from_civil(y, m, dd), d);
        }
        let t = datetime_from_ms(1_786_846_215_123);
        assert_eq!((t.year, t.month, t.day), (2026, 8, 16));
        assert_eq!(t.millis, 123);
        assert_eq!(t.file_stamp().len(), "2026-08-16_18-37-57".len());
    }

    #[test]
    fn relogio_manual() {
        let c = ManualClock::new(1000);
        c.advance(500);
        assert_eq!(c.now_utc_ms(), 1500);
        assert_eq!(c.monotonic_ms(), 500);
    }
}
