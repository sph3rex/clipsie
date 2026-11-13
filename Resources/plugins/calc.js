let q = text.toLowerCase().trim().replace(/^(?:what\s+is|what's|calc(?:ulate)?|compute)\s+/, "");
if (q.endsWith("?")) q = q.slice(0, -1).trimEnd();
for (const suffix of ["=", " equals", " equal", " is"]) {
  if (q.endsWith(suffix)) {
    q = q.slice(0, -suffix.length).trimEnd();
    break;
  }
}
q = q.replace(/(\d),(?=\d{3}\b)/g, "$1");
if (q === "") return null;

const units = {};
function unit(dim, factor, name, ...aliases) {
  for (const key of [name, ...aliases]) units[key.toLowerCase()] = [factor, name, dim];
}
unit("length", 1, "m", "meter", "meters", "metre", "metres");
unit("length", 1e-3, "mm", "millimeter", "millimeters", "millimetre", "millimetres");
unit("length", 1e-2, "cm", "centimeter", "centimeters", "centimetre", "centimetres");
unit("length", 1e3, "km", "kilometer", "kilometers", "kilometre", "kilometres");
unit("length", 0.0254, "in", "inch", "inches");
unit("length", 0.3048, "ft", "foot", "feet");
unit("length", 0.9144, "yd", "yard", "yards");
unit("length", 1609.344, "mi", "mile", "miles");
unit("length", 1852, "nmi", "nautical mile", "nautical miles");
unit("mass", 1, "g", "gram", "grams", "gramme", "grammes");
unit("mass", 1e-3, "mg", "milligram", "milligrams");
unit("mass", 1e3, "kg", "kilo", "kilos", "kilogram", "kilograms");
unit("mass", 1e6, "t", "tonne", "tonnes", "ton", "tons");
unit("mass", 28.349523125, "oz", "ounce", "ounces");
unit("mass", 453.59237, "lb", "lbs", "pound", "pounds");
unit("mass", 6350.29318, "st", "stone", "stones");
unit("volume", 1, "l", "liter", "liters", "litre", "litres");
unit("volume", 1e-3, "ml", "milliliter", "milliliters", "millilitre", "millilitres");
unit("volume", 1e-2, "cl", "centiliter", "centiliters", "centilitre", "centilitres");
unit("volume", 3.785411784, "gal", "gallon", "gallons");
unit("volume", 0.946352946, "qt", "quart", "quarts");
unit("volume", 0.473176473, "pt", "pint", "pints");
unit("volume", 0.2365882365, "cup", "cups");
unit("volume", 0.0295735295625, "fl oz", "floz", "fluid ounce", "fluid ounces");
unit("time", 1, "s", "sec", "secs", "second", "seconds");
unit("time", 1e-3, "ms", "millisecond", "milliseconds");
unit("time", 60, "min", "mins", "minute", "minutes");
unit("time", 3600, "h", "hr", "hrs", "hour", "hours");
unit("time", 86400, "d", "day", "days");
unit("time", 604800, "wk", "week", "weeks");
unit("time", 31557600, "yr", "year", "years");
unit("data", 1, "B", "b", "byte", "bytes");
unit("data", 1e3, "kB", "kb", "kilobyte", "kilobytes");
unit("data", 1e6, "MB", "mb", "megabyte", "megabytes");
unit("data", 1e9, "GB", "gb", "gigabyte", "gigabytes");
unit("data", 1e12, "TB", "tb", "terabyte", "terabytes");
unit("data", 1024, "KiB", "kib", "kibibyte", "kibibytes");
unit("data", 1024 ** 2, "MiB", "mib", "mebibyte", "mebibytes");
unit("data", 1024 ** 3, "GiB", "gib", "gibibyte", "gibibytes");
unit("data", 1024 ** 4, "TiB", "tib", "tebibyte", "tebibytes");
unit("speed", 1, "m/s", "mps", "meters per second");
unit("speed", 1000 / 3600, "km/h", "kmh", "kph", "kilometers per hour");
unit("speed", 1609.344 / 3600, "mph", "miles per hour");
unit("speed", 1852 / 3600, "kn", "knot", "knots");
unit("area", 1, "m²", "m2", "sqm", "square meter", "square meters");
unit("area", 1e6, "km²", "km2", "square kilometer", "square kilometers");
unit("area", 0.09290304, "ft²", "ft2", "sqft", "square foot", "square feet");
unit("area", 1e4, "ha", "hectare", "hectares");
unit("area", 4046.8564224, "ac", "acre", "acres");
const temps = {};
for (const t of ["c", "°c", "celsius", "centigrade"]) temps[t] = "C";
for (const t of ["f", "°f", "fahrenheit"]) temps[t] = "F";
for (const t of ["k", "kelvin", "kelvins"]) temps[t] = "K";

function fmt(n) {
  if (Number.isNaN(n)) return "NaN";
  if (!Number.isFinite(n)) return n < 0 ? "-Inf" : "Inf";
  const digits = Math.abs(n) >= 1e10 && Math.abs(n) < 1e15 ? 12 : 10;
  const s = String(Number(n.toPrecision(digits)));
  return s === "-0" ? "0" : s;
}
const toC = { C: (v) => v, F: (v) => ((v - 32) * 5) / 9, K: (v) => v - 273.15 };
const fromC = { C: (v) => v, F: (v) => (v * 9) / 5 + 32, K: (v) => v + 273.15 };

const leadingNumber = /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?/.exec(q);
if (leadingNumber) {
  const words = q.slice(leadingNumber[0].length).trim().split(/\s+/);
  const connector = words.findIndex((w, i) => i > 0 && i < words.length - 1 && ["to", "in", "into", "as", "->", "="].includes(w));
  if (connector > 0) {
    const value = Number(leadingNumber[0]);
    const from = words.slice(0, connector).join(" "), to = words.slice(connector + 1).join(" ");
    if (temps[from] && temps[to]) {
      const s = fmt(fromC[temps[to]](toC[temps[from]](value)));
      return { value: s, title: `${fmt(value)} °${temps[from]} = ${s} °${temps[to]}` };
    }
    const f = units[from], t = units[to];
    if (f && t && f[2] === t[2]) {
      const s = fmt((value * f[0]) / t[0]);
      return { value: s, title: `${fmt(value)} ${f[1]} = ${s} ${t[1]}` };
    }
    return null;
  }
}

const isNumber = (t) => /^(?:\d|\.\d)/.test(t);
const math = { sqrt: Math.sqrt, sin: Math.sin, cos: Math.cos, log: Math.log, exp: Math.exp, abs: Math.abs, int: Math.trunc };
const operators = new Set(["+", "-", "*", "/", "%", "**", "(", ")"]);
const phrases = [
  [["multiplied", "by"], ["*"]], [["times"], ["*"]], [["x"], ["*"]], [["×"], ["*"]],
  [["divided", "by"], ["/"]], [["over"], ["/"]], [["÷"], ["/"]], [["plus"], ["+"]], [["minus"], ["-"]],
  [["to", "the", "power", "of"], ["**"]], [["^"], ["**"]], [["squared"], ["**", "2"]], [["cubed"], ["**", "3"]],
  [["mod"], ["%"]], [["modulo"], ["%"]], [["square", "root", "of"], ["sqrt"]], [["ln"], ["log"]],
  [["pi"], ["3.14159265358979"]],
];
const words = q.match(/[\d.]+(?:e[-+]?\d+)?|[a-z]+|\*\*|\S/g) || [];
const tokens = [];
for (let i = 0; i < words.length; ) {
  if (isNumber(words[i]) && words[i + 1] === "%" && words[i + 2] === "of") {
    tokens.push("(", words[i], "/", "100", ")", "*");
    i += 3;
    continue;
  }
  const phrase = phrases.find(([match]) => match.every((w, k) => words[i + k] === w));
  if (phrase) {
    tokens.push(...phrase[1]);
    i += phrase[0].length;
  } else {
    tokens.push(words[i]);
    i += 1;
  }
}
if (!tokens.every((t) => isNumber(t) || operators.has(t) || Object.hasOwn(math, t))) return null;
if (!tokens.some(isNumber) || !tokens.some((t) => (operators.has(t) && t !== "(" && t !== ")") || Object.hasOwn(math, t))) return null;
if (tokens.length === 2 && tokens[0] === "-" && isNumber(tokens[1])) return null;

let at = 0;
function take(t) {
  if (tokens[at] !== t) return false;
  at += 1;
  return true;
}
function expression() {
  let v = term();
  for (;;) {
    if (take("+")) v += term();
    else if (take("-")) v -= term();
    else return v;
  }
}
function term() {
  let v = unary();
  for (;;) {
    if (take("*")) v *= unary();
    else if (take("/")) v /= unary();
    else if (take("%")) v %= unary();
    else return v;
  }
}
function unary() {
  if (take("-")) return -unary();
  if (take("+")) return unary();
  return power();
}
function power() {
  const base = primary();
  return take("**") ? base ** unary() : base;
}
function primary() {
  const t = tokens[at];
  at += 1;
  if (t === "(") {
    const v = expression();
    if (!take(")")) throw new Error("unclosed");
    return v;
  }
  if (Object.hasOwn(math, t)) return math[t](take("-") ? -primary() : primary());
  if (t !== undefined && isNumber(t)) return Number(t);
  throw new Error("unexpected " + t);
}
let r;
try {
  r = expression();
} catch {
  return null;
}
if (at !== tokens.length || !Number.isFinite(r)) return null;
const s = fmt(r);
return { value: s, title: `${q.replace(/\s+/g, " ")} = ${s}` };
