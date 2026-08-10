document.addEventListener('DOMContentLoaded', function () {
  var tables = document.querySelectorAll('.main-content table');
  tables.forEach(function (table) {
    var tbody = table.querySelector('tbody') || table;
    var rows = Array.prototype.slice.call(tbody.querySelectorAll('tr')).filter(function (row) {
      return row.querySelectorAll('td').length > 0;
    });
    if (rows.length === 0) return;

    var button = document.createElement('button');
    button.textContent = 'Roll';
    button.className = 'table-roll-btn';
    button.addEventListener('click', function () {
      rows.forEach(function (row) { row.classList.remove('rolled'); });
      var pick = rows[Math.floor(Math.random() * rows.length)];
      pick.classList.add('rolled');
      pick.scrollIntoView({ behavior: 'smooth', block: 'center' });
    });
    table.parentNode.insertBefore(button, table);
  });
});