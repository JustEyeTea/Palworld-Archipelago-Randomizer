// Turns the options page's choices into a player YAML. Kept free of the page (no DOM) so the test can run it
// outside a browser (tools/test_options_page.py). The output follows Archipelago 0.6.8's template generator
// (Options.generate_yaml_templates with data/options.yaml) line for line: for the defaults and each preset, with the
// name Player{number}, it is the same text as the Launcher's "Generate Template Options" files.
//
// `data` is options.json. `values` maps each option key the page has a control for to its value: a choice's name
// ("towers", "true"...) or a range's number. Options without a control (item and location names) are written with
// their defaults, as the template does.

'use strict';

// The options the page shows a control for: choices, toggles and ranges.
function isRange(option) { return typeof option.min === 'number'; }
function isChoice(option) { return Array.isArray(option.choices); }
function hasControl(option) { return isRange(option) || isChoice(option); }

function allOptions(data) {
  var list = [];
  data.groups.forEach(function (group) { list = list.concat(group.options); });
  return list;
}

// Python's == between a preset value and a choice: False and True count as 0 and 1.
function sameValue(a, b) {
  if (typeof a === 'boolean') a = a ? 1 : 0;
  if (typeof b === 'boolean') b = b ? 1 : 0;
  return a === b;
}

// The choice a value picks, by name or by number, or null.
function findChoice(option, value) {
  for (var i = 0; i < option.choices.length; i++) {
    var choice = option.choices[i];
    if (choice.name === value || sameValue(choice.value, value)) return choice;
  }
  return null;
}

function defaultValues(data) {
  var values = {};
  allOptions(data).forEach(function (option) {
    if (hasControl(option)) values[option.key] = option.default;
  });
  return values;
}

// The form values a preset sets: the defaults, with the preset's own values turned into what the controls hold
// (a choice's name, a range's number). The preset named '' is the defaults.
function presetValues(data, presetName) {
  var values = defaultValues(data);
  var preset = (presetName && data.presets[presetName]) || {};
  allOptions(data).forEach(function (option) {
    if (!(option.key in preset) || !hasControl(option)) return;
    var value = preset[option.key];
    if (isChoice(option)) {
      var choice = findChoice(option, value);
      if (choice) value = choice.name;
    } else if (typeof value === 'string' && option.named_values && value in option.named_values) {
      value = option.named_values[value];
    }
    values[option.key] = value;
  });
  return values;
}

function sameValues(data, a, b) {
  return allOptions(data).every(function (option) {
    return !hasControl(option) || a[option.key] === b[option.key];
  });
}

// YAML 1.1 words that PyYAML would read as booleans or null rather than text.
var YAML_WORDS = /^(y|yes|n|no|true|false|on|off|null|~)$/i;

// A player name or other text as a YAML scalar: as it is when YAML reads it back unchanged (which keeps
// Player{number} as the template writes it), otherwise double-quoted (JSON's string syntax is valid YAML).
function yamlScalar(text) {
  if (/^[A-Za-z][A-Za-z0-9_ .{}\-]*$/.test(text) && !/ $/.test(text) && !YAML_WORDS.test(text)) return text;
  return JSON.stringify(text);
}

// The weighted entries the template writes for a range (its dictify_range), as [key, weight, note] in its order.
function rangeEntries(option, value) {
  var entries = [[value, 50]];
  var notes = {};
  var randoms = ['random', 'random-low', 'random-high', 'random-range-' + option.min + '-' + option.max];
  randoms.forEach(function (name) { if (name !== value) entries.push([name, 0]); });
  notes['random-low'] = 'random value weighted towards lower values';
  notes['random-high'] = 'random value weighted towards higher values';
  notes[randoms[3]] = 'random value between ' + option.min + ' and ' + option.max;
  var index = function (key) {
    for (var i = 0; i < entries.length; i++) if (entries[i][0] === key) return i;
    return -1;
  };
  Object.keys(option.named_values || {}).forEach(function (name) {
    var number = option.named_values[name];
    notes[name] = 'equivalent to ' + number;
    var at = index(number);
    if (at >= 0) {
      // A value with a name is written by its name, moved to the end as the template's dict does.
      var weight = entries[at][1];
      entries.splice(at, 1);
      entries.push([name, weight]);
    } else if (index(name) < 0) {
      entries.push([name, 0]);
    }
  });
  return entries.map(function (entry) {
    return [entry[0], entry[1], notes[entry[0]] || ''];
  });
}

function optionLines(option, value) {
  var lines = ['  ' + option.key + ':'];
  if (option.help) {
    option.help.split('\n').forEach(function (line) { lines.push('    # ' + line); });
    if (isRange(option)) lines.push('    #');
  }
  if (isRange(option)) {
    lines.push('    # You can define additional values between the minimum and maximum values.');
    lines.push('    # Minimum value is ' + option.min);
    lines.push('    # Maximum value is ' + option.max);
    rangeEntries(option, value).forEach(function (entry) {
      lines.push('    ' + entry[0] + ': ' + entry[1] + (entry[2] ? ' # ' + entry[2] : ''));
    });
  } else if (isChoice(option)) {
    var picked = findChoice(option, value);
    option.choices.forEach(function (choice) {
      lines.push('    ' + choice.yaml + ': ' + (choice === picked ? 50 : 0));
    });
    // A value that is none of the choices (say, "random" in a preset) is added as its own entry, as the template
    // does.
    if (!picked) lines.push('    ' + yamlScalar(String(value)) + ': 50');
  } else {
    lines.push('    ' + option.yaml_value);
  }
  return lines;
}

// Which description the file gets: the preset's (or the default template's) while the form still matches it,
// otherwise a custom one.
function descriptionFor(data, values, presetName) {
  presetName = presetName || '';
  if (sameValues(data, values, presetValues(data, presetName))) return data.descriptions[presetName];
  return data.descriptions.custom;
}

function buildYaml(data, values, playerName, presetName) {
  var lines = [
    data.yaml_header + 'name: ' + yamlScalar(playerName),
    '',
    '# Used to describe your yaml. Useful if you have multiple files.',
    'description: ' + descriptionFor(data, values, presetName),
    '',
    'game: ' + data.game_yaml,
    'requires:',
    '  version: ' + data.archipelago_version + ' # Version of Archipelago required for this yaml to work as expected.'
  ];
  if (data.world_version !== '0.0.0') {
    lines.push('  game:');
    lines.push('    ' + data.game_yaml + ': ' + data.world_version +
               ' # Version of the world required for this yaml to work as expected.');
  }
  lines.push('');
  lines.push(data.game_yaml + ':');
  data.groups.forEach(function (group) {
    var bar = '  ' + new Array(group.name.length + 5).join('#');
    lines.push(bar, '  # ' + group.name + ' #', bar);
    group.options.forEach(function (option) {
      var value = hasControl(option) && option.key in values ? values[option.key] : option.default;
      lines = lines.concat(optionLines(option, value));
      lines.push('');
    });
  });
  lines.pop();  // the template ends after the last option's lines, without a blank line
  return lines.join('\n') + '\n';
}

// What's wrong with a player name, or '' if Archipelago will take it. Archipelago (Generate.handle_name) fills in
// {number}, {NUMBER}, {player} and {PLAYER}, then keeps the first 16 characters; its website's form allows 16.
function nameProblem(name) {
  if (!name.trim()) return 'Enter a player name.';
  if (name !== name.trim()) return 'The name can\'t start or end with a space.';
  if (Array.from(name).length > 16) return 'The name can be at most 16 characters.';
  if (name === 'Archipelago') return 'Archipelago doesn\'t allow the name "Archipelago".';
  if (/[{}]/.test(name.replace(/\{(number|NUMBER|player|PLAYER)\}/g, ''))) {
    return 'Braces are only for {number}, {NUMBER}, {player} or {PLAYER}.';
  }
  return '';
}

// What's wrong with a range's value, or ''.
function valueProblem(option, value) {
  if (!isRange(option)) return '';
  if (typeof value !== 'number' || !isFinite(value) || Math.floor(value) !== value) return 'Enter a whole number.';
  if (value < option.min || value > option.max) return 'Enter a number from ' + option.min + ' to ' + option.max + '.';
  // Values inside the range that generation refuses all the same (options.json's `refused`, from the APWorld).
  if (option.refused && option.refused.values.indexOf(value) >= 0) return option.refused.problem;
  return '';
}
