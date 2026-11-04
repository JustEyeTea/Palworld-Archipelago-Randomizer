// The options page: builds a form from options.json (written by tools/gen_options_page.py from the APWorld) and
// downloads the player YAML that build-yaml.js writes from it.

'use strict';

(function () {
  var data = null;
  var form = document.getElementById('options-form');
  var nameInput = document.getElementById('player-name');
  var presetSelect = document.getElementById('preset');
  var NAME_KEY = 'palworld-archipelago-player-name';

  // "relic_hunt" -> "Relic Hunt", as Archipelago's own options pages show a choice's name.
  function choiceLabel(name) {
    return name.replace(/_/g, ' ').replace(/\b\w/g, function (c) { return c.toUpperCase(); });
  }

  function element(tag, attributes, text) {
    var node = document.createElement(tag);
    Object.keys(attributes || {}).forEach(function (key) { node.setAttribute(key, attributes[key]); });
    if (text) node.textContent = text;
    return node;
  }

  // Docstrings are wrapped at the code's line width; the YAML keeps that, but on the page a wrapped line is joined
  // back up. A line counts as wrapped when it is long and doesn't end a sentence, so the Goal option's one-line
  // entries stay on their own lines. Blank lines make paragraphs and **text** is bold, as Archipelago's docs write.
  function fillHelp(node, text) {
    text.split(/\n\s*\n/).forEach(function (paragraph, index) {
      var lines = paragraph.split('\n');
      var joined = [lines[0]];
      for (var i = 1; i < lines.length; i++) {
        var previous = joined[joined.length - 1];
        if (previous.length >= 90 && !/[.:;!?]$/.test(previous)) joined[joined.length - 1] = previous + ' ' + lines[i];
        else joined.push(lines[i]);
      }
      if (index) node.appendChild(document.createElement('br'));
      joined.forEach(function (line, n) {
        if (n || index) node.appendChild(document.createElement('br'));
        line.split(/\*\*(.+?)\*\*/).forEach(function (part, odd) {
          node.appendChild(odd % 2 ? element('strong', {}, part) : document.createTextNode(part));
        });
      });
    });
    return node;
  }

  function isToggle(option) {
    return isChoice(option) && option.choices.length === 2 &&
      option.choices[0].name === 'false' && option.choices[1].name === 'true';
  }

  // One option's label, control and help text.
  function optionField(option) {
    var id = 'option-' + option.key;
    var field = element('div', { 'class': 'field', 'data-key': option.key });
    var describedBy = [];
    var help = null;
    if (option.help) {
      help = fillHelp(element('p', { 'class': 'help', id: id + '-help' }), option.help);
      describedBy.push(help.id);
    }
    var error = element('p', { 'class': 'error', id: id + '-error', 'aria-live': 'polite' });
    describedBy.push(error.id);

    if (isToggle(option)) {
      field.classList.add('toggle');
      var box = element('input', { type: 'checkbox', id: id, 'aria-describedby': describedBy.join(' ') });
      var label = element('label', { 'for': id }, option.name);
      field.appendChild(box);
      field.appendChild(label);
    } else if (isChoice(option)) {
      field.appendChild(element('label', { 'for': id }, option.name));
      var select = element('select', { id: id, 'aria-describedby': describedBy.join(' ') });
      option.choices.forEach(function (choice) {
        select.appendChild(element('option', { value: choice.name }, choiceLabel(choice.name)));
      });
      field.appendChild(select);
    } else {
      field.appendChild(element('label', { 'for': id }, option.name));
      var row = element('div', { 'class': 'range' });
      // The slider is a quicker way to set the same number; the number box is the labelled control.
      var slider = element('input', { type: 'range', min: option.min, max: option.max, step: 1,
                                      'aria-label': option.name + ' (slider)', id: id + '-slider' });
      var number = element('input', { type: 'number', id: id, min: option.min, max: option.max, step: 1,
                                      inputmode: 'numeric', 'aria-describedby': describedBy.join(' ') });
      // The form's input listener sees the slider's events too and updates the rest.
      slider.addEventListener('input', function () { number.value = slider.value; });
      number.addEventListener('input', function () {
        if (number.value !== '') slider.value = number.value;
      });
      row.appendChild(slider);
      row.appendChild(number);
      field.appendChild(row);
      var range = 'From ' + option.min + ' to ' + option.max + '.';
      var named = Object.keys(option.named_values || {}).map(function (name) {
        return option.named_values[name] + ' is ' + name;
      });
      if (named.length) range += ' ' + named.join(', ') + '.';
      field.appendChild(element('p', { 'class': 'help range-note' }, range));
    }
    if (help) field.appendChild(help);
    field.appendChild(error);
    return field;
  }

  function buildForm() {
    var container = document.getElementById('groups');
    data.groups.forEach(function (group, index) {
      var controls = group.options.filter(hasControl);
      var others = group.options.filter(function (option) { return !hasControl(option); });
      var section = element('fieldset', { 'class': 'panel' });
      section.appendChild(element('legend', {}, group.name));
      controls.forEach(function (option) { section.appendChild(optionField(option)); });
      if (others.length) {
        // Item and location lists take names from the game's item and location lists; there are too many to
        // pick from here, so the file carries them empty, ready to edit.
        var details = element('details', {});
        if (!group.start_collapsed) details.open = true;
        details.appendChild(element('summary', {},
          controls.length ? 'More options, set in the file' : 'These options are set in the file'));
        details.appendChild(element('p', { 'class': 'help' },
          'These take lists of item or location names. The downloaded YAML has them empty; ' +
          'edit them there if you want them.'));
        var list = element('dl', { 'class': 'file-options' });
        others.forEach(function (option) {
          list.appendChild(element('dt', {}, option.name + ' (' + option.key + ')'));
          list.appendChild(fillHelp(element('dd', {}), option.help));
        });
        details.appendChild(list);
        section.appendChild(details);
      }
      container.appendChild(section);
    });

    presetSelect.appendChild(element('option', { value: '' }, 'Defaults'));
    Object.keys(data.presets).forEach(function (name) {
      presetSelect.appendChild(element('option', { value: name }, name));
    });

    var built = document.getElementById('built-from');
    built.textContent = ' · Built from APWorld ' + data.world_version + ', for Archipelago ' +
      data.archipelago_version + '.';
  }

  function control(key) { return document.getElementById('option-' + key); }

  function setValues(values) {
    allOptions(data).filter(hasControl).forEach(function (option) {
      var input = control(option.key);
      var value = values[option.key];
      if (isToggle(option)) input.checked = value === 'true';
      else if (isChoice(option)) input.value = value;
      else {
        input.value = value;
        document.getElementById('option-' + option.key + '-slider').value = value;
      }
    });
  }

  function readValues() {
    var values = {};
    allOptions(data).filter(hasControl).forEach(function (option) {
      var input = control(option.key);
      if (isToggle(option)) values[option.key] = input.checked ? 'true' : 'false';
      else if (isChoice(option)) values[option.key] = input.value;
      else values[option.key] = input.value === '' ? NaN : Number(input.value);
    });
    return values;
  }

  // Shows each problem beside its field and returns the first field with one, or null.
  function check(values) {
    var first = null;
    var nameError = nameProblem(nameInput.value);
    document.getElementById('player-name-error').textContent = nameError;
    nameInput.setAttribute('aria-invalid', nameError ? 'true' : 'false');
    if (nameError) first = nameInput;
    allOptions(data).filter(isRange).forEach(function (option) {
      var problem = valueProblem(option, values[option.key]);
      var input = control(option.key);
      document.getElementById('option-' + option.key + '-error').textContent = problem;
      input.setAttribute('aria-invalid', problem ? 'true' : 'false');
      if (problem && !first) first = input;
    });
    return first;
  }

  function changed() {
    var values = readValues();
    var preset = presetSelect.value;
    var matches = sameValues(data, values, presetValues(data, preset));
    document.getElementById('preset-status').textContent = matches ? '' :
      'Changed from ' + (preset || 'the defaults') + '.';
    // Range problems show as they're typed; the name's only once a download has been tried (see check).
    var problems = false;
    allOptions(data).filter(isRange).forEach(function (option) {
      var problem = valueProblem(option, values[option.key]);
      document.getElementById('option-' + option.key + '-error').textContent = problem;
      control(option.key).setAttribute('aria-invalid', problem ? 'true' : 'false');
      if (problem) problems = true;
    });
    document.getElementById('preview').textContent = problems ? 'Fix the options marked above to see the YAML.' :
      buildYaml(data, values, nameInput.value || 'Player{number}', preset);
  }

  function download(event) {
    event.preventDefault();
    var values = readValues();
    var problem = check(values);
    document.getElementById('form-error').textContent = problem ? 'Fix the fields marked above first.' : '';
    if (problem) { problem.focus(); return; }
    var text = buildYaml(data, values, nameInput.value, presetSelect.value);
    var blob = new Blob([text], { type: 'application/yaml' });
    var link = element('a', { href: URL.createObjectURL(blob),
                              download: nameInput.value.replace(/[\\\/:*?"<>|{}]/g, '_') + '.yaml' });
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(function () { URL.revokeObjectURL(link.href); }, 1000);
  }

  function start(json) {
    data = json;
    buildForm();
    setValues(defaultValues(data));
    // The name is remembered in this browser only, for the next visit; the page works the same without it.
    try { nameInput.value = localStorage.getItem(NAME_KEY) || ''; } catch (e) { /* storage blocked */ }
    presetSelect.addEventListener('change', function () {
      setValues(presetValues(data, presetSelect.value));
      changed();
    });
    form.addEventListener('input', function (event) {
      if (event.target === presetSelect) return;
      if (event.target === nameInput) {
        try { localStorage.setItem(NAME_KEY, nameInput.value); } catch (e) { /* storage blocked */ }
        if (document.getElementById('player-name-error').textContent) check(readValues());
      }
      changed();
    });
    form.addEventListener('submit', download);
    form.hidden = false;
    changed();
  }

  fetch('options.json')
    .then(function (response) {
      if (!response.ok) throw new Error('options.json: ' + response.status);
      return response.json();
    })
    .then(start)
    .catch(function (error) {
      var message = document.getElementById('load-error');
      message.textContent = 'The options could not be loaded (' + error.message + '). ' +
        'If you opened this file from your disk, serve the folder instead (python3 -m http.server).';
      message.hidden = false;
    });
}());
