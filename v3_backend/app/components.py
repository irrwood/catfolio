"""Shared UI components used across route modules."""

import hashlib as _hashlib
import re as _re
import time as _time
from datetime import datetime, timezone
from functools import lru_cache as _lru_cache
from pathlib import Path
from app.data_store import current_snapshot, demo_mode
from app.i18n import t_block

_STATIC_DIR = Path(__file__).resolve().parent / "static"

_HUGEICON_SYMBOLS = """<svg class="hugeicons-sprite" aria-hidden="true" focusable="false">
  <symbol id="hi-dashboard" viewBox="0 0 24 24">
    <path d="M10.5 8.75V6.75C10.5 5.10626 10.5 4.28439 10.046 3.73121C9.96291 3.62995 9.87005 3.53709 9.76879 3.45398C9.21561 3 8.39374 3 6.75 3C5.10626 3 4.28439 3 3.73121 3.45398C3.62995 3.53709 3.53709 3.62995 3.45398 3.73121C3 4.28439 3 5.10626 3 6.75V8.75C3 10.3937 3 11.2156 3.45398 11.7688C3.53709 11.8701 3.62995 11.9629 3.73121 12.046C4.28439 12.5 5.10626 12.5 6.75 12.5C8.39374 12.5 9.21561 12.5 9.76879 12.046C9.87005 11.9629 9.96291 11.8701 10.046 11.7688C10.5 11.2156 10.5 10.3937 10.5 8.75Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M7.75 15.5H5.75C5.05222 15.5 4.70333 15.5 4.41943 15.5861C3.78023 15.78 3.28002 16.2802 3.08612 16.9194C3 17.2033 3 17.5522 3 18.25C3 18.9478 3 19.2967 3.08612 19.5806C3.28002 20.2198 3.78023 20.72 4.41943 20.9139C4.70333 21 5.05222 21 5.75 21H7.75C8.44778 21 8.79667 21 9.08057 20.9139C9.71977 20.72 10.22 20.2198 10.4139 19.5806C10.5 19.2967 10.5 18.9478 10.5 18.25C10.5 17.5522 10.5 17.2033 10.4139 16.9194C10.22 16.2802 9.71977 15.78 9.08057 15.5861C8.79667 15.5 8.44778 15.5 7.75 15.5Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M21 17.25V15.25C21 13.6063 21 12.7844 20.546 12.2312C20.4629 12.1299 20.3701 12.0371 20.2688 11.954C19.7156 11.5 18.8937 11.5 17.25 11.5C15.6063 11.5 14.7844 11.5 14.2312 11.954C14.1299 12.0371 14.0371 12.1299 13.954 12.2312C13.5 12.7844 13.5 13.6063 13.5 15.25V17.25C13.5 18.8937 13.5 19.7156 13.954 20.2688C14.0371 20.3701 14.1299 20.4629 14.2312 20.546C14.7844 21 15.6063 21 17.25 21C18.8937 21 19.7156 21 20.2688 20.546C20.3701 20.4629 20.4629 20.3701 20.546 20.2688C21 19.7156 21 18.8937 21 17.25Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M18.25 3H16.25C15.5522 3 15.2033 3 14.9194 3.08612C14.2802 3.28002 13.78 3.78023 13.5861 4.41943C13.5 4.70333 13.5 5.05222 13.5 5.75C13.5 6.44778 13.5 6.79667 13.5861 7.08057C13.78 7.71977 14.2802 8.21998 14.9194 8.41388C15.2033 8.5 15.5522 8.5 16.25 8.5H18.25C18.9478 8.5 19.2967 8.5 19.5806 8.41388C20.2198 8.21998 20.72 7.71977 20.9139 7.08057C21 6.79667 21 6.44778 21 5.75C21 5.05222 21 4.70333 20.9139 4.41943C20.72 3.78023 20.2198 3.28002 19.5806 3.08612C19.2967 3 18.9478 3 18.25 3Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-lab" viewBox="0 0 24 24">
    <path d="M17.5 21C15.567 21 14 19.433 14 17.5L14 3L21 3L21 17.5C21 19.433 19.433 21 17.5 21Z" stroke="currentColor" stroke-width="1.5"></path>
    <path d="M22 3L13 3" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M17 7H14" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M10 16.875C10 19.9126 8 21 6 21C4 21 2 19.9126 2 16.875C2 13.8374 6 10 6 10C6 10 10 13.8374 10 16.875Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M14 12C15.083 11.1336 16.2974 9.87843 17.771 10.7626C19.0014 11.5009 20.0342 10.7244 21 10" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-calculator" viewBox="0 0 24 24">
    <path d="M5.5 3V8M8 5.5L3 5.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M8 16L6 18M6 18L4 20M6 18L8 20M6 18L4 16" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M20 6L16 6" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M20 18.5L16 18.5M20 15.5L16 15.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M22 12L2 12" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M12 22L12 2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-strategy" viewBox="0 0 24 24">
    <path d="M10.5 2V4M13.5 2V4M8 6.5H6M8 9.5H6M18 6.5H16M18 9.5H16M13.3333 4H10.6667C9.40959 4 8.78105 4 8.39052 4.39052C8 4.78105 8 5.40959 8 6.66667V9.33333C8 10.5904 8 11.219 8.39052 11.6095C8.78105 12 9.40959 12 10.6667 12H13.3333C14.5904 12 15.219 12 15.6095 11.6095C16 11.219 16 10.5904 16 9.33333V6.66667C16 5.40959 16 4.78105 15.6095 4.39052C15.219 4 14.5904 4 13.3333 4Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M3.61732 21.9239C3.80109 22 4.03406 22 4.5 22C4.96594 22 5.19891 22 5.38268 21.9239C5.62771 21.8224 5.82239 21.6277 5.92388 21.3827C6 21.1989 6 20.9659 6 20.5C6 20.0341 6 19.8011 5.92388 19.6173C5.82239 19.3723 5.62771 19.1776 5.38268 19.0761C5.19891 19 4.96594 19 4.5 19C4.03406 19 3.80109 19 3.61732 19.0761C3.37229 19.1776 3.17761 19.3723 3.07612 19.6173C3 19.8011 3 20.0341 3 20.5C3 20.9659 3 21.1989 3.07612 21.3827C3.17761 21.6277 3.37229 21.8224 3.61732 21.9239Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M11.1173 21.9239C11.3011 22 11.5341 22 12 22C12.4659 22 12.6989 22 12.8827 21.9239C13.1277 21.8224 13.3224 21.6277 13.4239 21.3827C13.5 21.1989 13.5 20.9659 13.5 20.5C13.5 20.0341 13.5 19.8011 13.4239 19.6173C13.3224 19.3723 13.1277 19.1776 12.8827 19.0761C12.6989 19 12.4659 19 12 19C11.5341 19 11.3011 19 11.1173 19.0761C10.8723 19.1776 10.6776 19.3723 10.5761 19.6173C10.5 19.8011 10.5 20.0341 10.5 20.5C10.5 20.9659 10.5 21.1989 10.5761 21.3827C10.6776 21.6277 10.8723 21.8224 11.1173 21.9239Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M12 19V12" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M4.5 19C4.5 17.5955 4.5 16.8933 4.83706 16.3889C4.98298 16.1705 5.17048 15.983 5.38886 15.8371C5.89331 15.5 6.59554 15.5 8 15.5H16C17.4045 15.5 18.1067 15.5 18.6111 15.8371C18.8295 15.983 19.017 16.1705 19.1629 16.3889C19.5 16.8933 19.5 17.5955 19.5 19" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M18.6173 21.9239C18.8011 22 19.0341 22 19.5 22C19.9659 22 20.1989 22 20.3827 21.9239C20.6277 21.8224 20.8224 21.6277 20.9239 21.3827C21 21.1989 21 20.9659 21 20.5C21 20.0341 21 19.8011 20.9239 19.6173C20.8224 19.3723 20.6277 19.1776 20.3827 19.0761C20.1989 19 19.9659 19 19.5 19C19.0341 19 18.8011 19 18.6173 19.0761C18.3723 19.1776 18.1776 19.3723 18.0761 19.6173C18 19.8011 18 20.0341 18 20.5C18 20.9659 18 21.1989 18.0761 21.3827C18.1776 21.6277 18.3723 21.8224 18.6173 21.9239Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-returns" viewBox="0 0 24 24">
    <circle cx="8.5" cy="10.5" r="1.5" stroke="currentColor" stroke-width="1.5"></circle>
    <circle cx="14.5" cy="15.5" r="1.5" stroke="currentColor" stroke-width="1.5"></circle>
    <circle cx="18.5" cy="7.5" r="1.5" stroke="currentColor" stroke-width="1.5"></circle>
    <path d="M15.4341 14.2963L18 9M9.58251 11.5684L13.2038 14.2963M3 19L7.58957 11.8792" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M20 21H9C5.70017 21 4.05025 21 3.02513 19.9749C2 18.9497 2 17.2998 2 14V3" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-heatmap" viewBox="0 0 24 24">
    <path d="M3.89124 3.89124C5.28249 2.5 7.52166 2.5 12 2.5C16.4783 2.5 18.7175 2.5 20.1088 3.89124C21.5 5.28249 21.5 7.52166 21.5 12C21.5 16.4783 21.5 18.7175 20.1088 20.1088C18.7175 21.5 16.4783 21.5 12 21.5C7.52166 21.5 5.28249 21.5 3.89124 20.1088C2.5 18.7175 2.5 16.4783 2.5 12C2.5 7.52166 2.5 5.28249 3.89124 3.89124Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M12 2.5V4.4M12 19.6V21.5M9.15 12H14.85M19.6 12H21.5M2.5 12H4.4M12 9.14999V14.85" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-ai" viewBox="0 0 24 24">
    <path d="M4 16.4999C4 18.1567 5.34315 19.4999 7 19.4999C7 20.8806 8.11929 21.9999 9.5 21.9999C10.8807 21.9999 12 20.8806 12 19.4999C12 20.8806 13.1193 21.9998 14.5 21.9998C15.8807 21.9998 17 20.8805 17 19.4998C18.6569 19.4998 20 18.1566 20 16.4998C20 15.9311 19.8418 15.3994 19.567 14.9463C20.9527 14.6812 22 13.4628 22 11.9998C22 10.5367 20.9527 9.31831 19.567 9.05325C19.8418 8.60012 20 8.06842 20 7.49976C20 5.8429 18.6569 4.49976 17 4.49976C17 3.11904 15.8807 1.99976 14.5 1.99976C13.1193 1.99976 12 3.11914 12 4.49985C12 3.11914 10.8807 1.99985 9.5 1.99985C8.11929 1.99985 7 3.11914 7 4.49985C5.34315 4.49985 4 5.843 4 7.49985C4 8.06851 4.15822 8.60022 4.43304 9.05335C3.04727 9.3184 2 10.5368 2 11.9999C2 13.4629 3.04727 14.6813 4.43304 14.9464C4.15822 15.3995 4 15.9312 4 16.4999Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M7.5 14.4999L9.34189 8.97422C9.43631 8.69095 9.7014 8.49988 10 8.49988C10.2986 8.49988 10.5637 8.69095 10.6581 8.97422L12.5 14.4999M15.5 8.49988V14.4999M8.5 12.4999H11.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-import" viewBox="0 0 24 24">
    <path d="M20 15.0057V10.6606C20 9.84276 20 9.43383 19.8478 9.06613C19.6955 8.69843 19.4065 8.40927 18.8284 7.83096L14.0919 3.09236C13.593 2.59325 13.3436 2.3437 13.0345 2.19583C12.9702 2.16508 12.9044 2.13778 12.8372 2.11406C12.5141 2 12.1614 2 11.4558 2C8.21082 2 6.58831 2 5.48933 2.88646C5.26731 3.06554 5.06508 3.26787 4.88607 3.48998C4 4.58943 4 6.21265 4 9.45908V14.0052C4 17.7781 4 19.6645 5.17157 20.8366C6.11466 21.7801 7.52043 21.9641 10 22M13 2.50022V3.00043C13 5.83009 13 7.24492 13.8787 8.12398C14.7574 9.00304 16.1716 9.00304 19 9.00304H19.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M15 22C14.3932 21.4102 12 19.8403 12 19C12 18.1597 14.3932 16.5898 15 16M13 19H20" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-settings" viewBox="0 0 24 24">
    <path d="M3.99963 5.00055L9.99963 5.00031" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M12.9996 5.00031L19.9996 5.00031" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M15.9996 9.00031L15.9996 15.0003" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M9.99963 2.00031L9.99963 8.00031" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M11.9996 16.0003L11.9996 22.0003" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M15.9996 12.0001L19.9996 12.0003" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M3.99963 12.0005L12.9996 12.0003" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M11.9996 19.0003L19.9996 19.0003" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M3.99963 19.0005L8.99963 19.0003" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-demo" viewBox="0 0 24 24">
    <path d="M5.5 13.3247C6.25954 13.1279 7.07646 13 8 13C11 13 14 16 17 16C17.5754 16 18.0713 15.947 18.5 15.8557" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M8 2H16" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M9.5 2V6.3951C9.5 7.25859 9.5 7.69034 9.34736 8.00229C9.19472 8.31425 8.69913 8.69945 7.70796 9.46982C6.06019 10.7505 5 12.7515 5 15C5 18.866 8.13401 22 12 22C15.866 22 19 18.866 19 15C19 12.7514 17.9398 10.7505 16.292 9.46982C15.3009 8.69944 14.8053 8.31425 14.6526 8.00229C14.5 7.69034 14.5 7.25859 14.5 6.3951V2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-moon" viewBox="0 0 24 24">
    <path d="M21.5 14.0784C20.3003 14.7189 18.9301 15.0821 17.4751 15.0821C12.7491 15.0821 8.91792 11.2509 8.91792 6.52485C8.91792 5.06986 9.28105 3.69968 9.92163 2.5C5.66765 3.49698 2.5 7.31513 2.5 11.8731C2.5 17.1899 6.8101 21.5 12.1269 21.5C16.6849 21.5 20.503 18.3324 21.5 14.0784Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-sun" viewBox="0 0 24 24">
    <path d="M16.9991 12C16.9991 14.7614 14.7605 17 11.9991 17C9.23766 17 6.99908 14.7614 6.99908 12C6.99908 9.23858 9.23766 7 11.9991 7C14.7605 7 16.9991 9.23858 16.9991 12Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M12.1247 3.25H11.9997M12.1242 20.75H11.9992M20.75 12.125V12M3.25 12.125V12M18.2752 5.90098L18.1868 5.81259M5.90051 18.275L5.81212 18.1866M18.0987 18.2756L18.187 18.1872M5.72429 5.9012L5.81267 5.81282M12.2497 3.25C12.2497 3.38807 12.1378 3.5 11.9997 3.5C11.8616 3.5 11.7497 3.38807 11.7497 3.25C11.7497 3.11193 11.8616 3 11.9997 3C12.1378 3 12.2497 3.11193 12.2497 3.25ZM12.2492 20.75C12.2492 20.8881 12.1373 21 11.9992 21C11.8611 21 11.7492 20.8881 11.7492 20.75C11.7492 20.6119 11.8611 20.5 11.9992 20.5C12.1373 20.5 12.2492 20.6119 12.2492 20.75ZM20.75 12.25C20.6119 12.25 20.5 12.1381 20.5 12C20.5 11.8619 20.6119 11.75 20.75 11.75C20.8881 11.75 21 11.8619 21 12C21 12.1381 20.8881 12.25 20.75 12.25ZM3.25 12.25C3.11193 12.25 3 12.1381 3 12C3 11.8619 3.11193 11.75 3.25 11.75C3.38807 11.75 3.5 11.8619 3.5 12C3.5 12.1381 3.38807 12.25 3.25 12.25ZM18.3636 5.98937C18.266 6.087 18.1077 6.087 18.01 5.98937C17.9124 5.89174 17.9124 5.73345 18.01 5.63582C18.1077 5.53819 18.266 5.53819 18.3636 5.63582C18.4612 5.73345 18.4612 5.89174 18.3636 5.98937ZM5.9889 18.3634C5.89127 18.461 5.73297 18.461 5.63534 18.3634C5.53771 18.2658 5.53771 18.1075 5.63534 18.0099C5.73297 17.9122 5.89127 17.9122 5.9889 18.0099C6.08653 18.1075 6.08653 18.2658 5.9889 18.3634ZM18.0103 18.364C17.9126 18.2663 17.9126 18.108 18.0103 18.0104C18.1079 17.9128 18.2662 17.9128 18.3638 18.0104C18.4614 18.108 18.4614 18.2663 18.3638 18.364C18.2662 18.4616 18.1079 18.4616 18.0103 18.364ZM5.6359 5.98959C5.53827 5.89196 5.53827 5.73367 5.6359 5.63604C5.73353 5.53841 5.89182 5.53841 5.98945 5.63604C6.08708 5.73367 6.08708 5.89196 5.98945 5.98959C5.89182 6.08722 5.73353 6.08722 5.6359 5.98959Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-theme-system" viewBox="0 0 24 24">
    <path d="M22 12C22 17.5227 17.5229 22 12 22C6.47713 22 2 17.5227 2 12C2 6.47713 6.47713 2 12 2C17.5229 2 22 6.47713 22 12Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M16.5 12C16.5 14.4852 14.4853 16.5 12 16.5C9.51471 16.5 7.5 14.4852 7.5 12C7.5 9.51471 9.51471 7.5 12 7.5C14.4853 7.5 16.5 9.51471 16.5 12Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M12 2V22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-menu" viewBox="0 0 24 24">
    <path d="M4 5L20 5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M4 12L20 12" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M4 19L20 19" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-refresh" viewBox="0 0 24 24">
    <path d="M3 12a9 9 0 0 1 15.3-6.4" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M21 12a9 9 0 0 1-15.3 6.4" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M18.3 5.6V3M18.3 5.6H21" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M5.7 18.4V21M5.7 18.4H3" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-spinner" viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-opacity="0.25" stroke-width="1.5"></circle>
    <path d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-bolt" viewBox="0 0 24 24">
    <path d="M13 2L4 14H11L9 22L20 9H13L13 2Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-target" viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.5"></circle>
    <circle cx="12" cy="12" r="5" stroke="currentColor" stroke-width="1.5"></circle>
    <circle cx="12" cy="12" r="1.2" fill="currentColor" stroke="none"></circle>
  </symbol>
  <symbol id="hi-calendar-day" viewBox="0 0 24 24">
    <rect x="3" y="5" width="18" height="16" rx="3" stroke="currentColor" stroke-width="1.5"></rect>
    <path d="M3 9.5H21" stroke="currentColor" stroke-width="1.5"></path>
    <path d="M8 3V6.5M16 3V6.5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <circle cx="12" cy="15" r="1.4" fill="currentColor" stroke="none"></circle>
  </symbol>
  <symbol id="hi-trending" viewBox="0 0 24 24">
    <path d="M3 17L9 11L13 15L21 7" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M15 7H21V13" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-check" viewBox="0 0 24 24">
    <path d="M5 12.5L9.5 17L19 6" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-check-circle" viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.5"></circle>
    <path d="M8.3 12.4L10.4 14.5L15.7 9.2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-info-circle" viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.5"></circle>
    <path d="M12 11V16.2" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <circle cx="12" cy="8" r="1" fill="currentColor" stroke="none"></circle>
  </symbol>
  <symbol id="hi-alert-circle" viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.5"></circle>
    <path d="M12 7.5V13" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <circle cx="12" cy="16.2" r="1" fill="currentColor" stroke="none"></circle>
  </symbol>
  <symbol id="hi-x-circle" viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.5"></circle>
    <path d="M9.5 9.5L14.5 14.5M14.5 9.5L9.5 14.5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-clock" viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="9" stroke="currentColor" stroke-width="1.5"></circle>
    <path d="M12 7.5V12.5L15.5 14.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-clone" viewBox="0 0 24 24">
    <rect x="8" y="8" width="13" height="13" rx="3" stroke="currentColor" stroke-width="1.5"></rect>
    <path d="M16 8V6.5A3.5 3.5 0 0 0 12.5 3H6.5A3.5 3.5 0 0 0 3 6.5V12.5A3.5 3.5 0 0 0 6.5 16H8" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-cloud-upload" viewBox="0 0 24 24">
    <path d="M7 17a4 4 0 0 1 .5-7.97A5.5 5.5 0 0 1 18 10.5a3.5 3.5 0 0 1-.7 6.93" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M12 20V13M9 15.3L12 12.3L15 15.3" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-code" viewBox="0 0 24 24">
    <path d="M9 6L4 12L9 18" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M15 6L20 12L15 18" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-comment-dots" viewBox="0 0 24 24">
    <rect x="3" y="4" width="18" height="13" rx="4" stroke="currentColor" stroke-width="1.5"></rect>
    <path d="M8 21L10.5 17" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <circle cx="8.5" cy="10.5" r="1" fill="currentColor" stroke="none"></circle>
    <circle cx="12" cy="10.5" r="1" fill="currentColor" stroke="none"></circle>
    <circle cx="15.5" cy="10.5" r="1" fill="currentColor" stroke="none"></circle>
  </symbol>
  <symbol id="hi-comments" viewBox="0 0 24 24">
    <rect x="2.5" y="4" width="14" height="10" rx="3" stroke="currentColor" stroke-width="1.5"></rect>
    <path d="M6.5 18L8.5 14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <rect x="8.5" y="9.5" width="13" height="9.5" rx="3" stroke="currentColor" stroke-width="1.5"></rect>
  </symbol>
  <symbol id="hi-database" viewBox="0 0 24 24">
    <ellipse cx="12" cy="6" rx="8" ry="3" stroke="currentColor" stroke-width="1.5"></ellipse>
    <path d="M4 6V12C4 13.66 7.58 15 12 15C16.42 15 20 13.66 20 12V6" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M4 12V18C4 19.66 7.58 21 12 21C16.42 21 20 19.66 20 18V12" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-download" viewBox="0 0 24 24">
    <path d="M12 3V15" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M7.5 11L12 15.5L16.5 11" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M4 17V19A2 2 0 0 0 6 21H18A2 2 0 0 0 20 19V17" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-upload" viewBox="0 0 24 24">
    <path d="M12 16V4" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M7.5 8.5L12 4L16.5 8.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M4 16V19A2 2 0 0 0 6 21H18A2 2 0 0 0 20 19V16" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-expand" viewBox="0 0 24 24">
    <path d="M9 4H6A2 2 0 0 0 4 6V9" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M15 4H18A2 2 0 0 1 20 6V9" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M9 20H6A2 2 0 0 1 4 18V15" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M15 20H18A2 2 0 0 0 20 18V15" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-compress" viewBox="0 0 24 24">
    <path d="M4 9H7A2 2 0 0 0 9 7V4" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M20 9H17A2 2 0 0 1 15 7V4" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M4 15H7A2 2 0 0 1 9 17V20" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M20 15H17A2 2 0 0 0 15 17V20" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-file" viewBox="0 0 24 24">
    <path d="M6 3H13L18 8V19A2 2 0 0 1 16 21H6A2 2 0 0 1 4 19V5A2 2 0 0 1 6 3Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M13 3V8H18" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-file-csv" viewBox="0 0 24 24">
    <path d="M6 3H13L18 8V19A2 2 0 0 1 16 21H6A2 2 0 0 1 4 19V5A2 2 0 0 1 6 3Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M13 3V8H18" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M8 14H14M8 17H14" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-file-import" viewBox="0 0 24 24">
    <path d="M6 3H13L18 8V19A2 2 0 0 1 16 21H6A2 2 0 0 1 4 19V5A2 2 0 0 1 6 3Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M13 3V8H18" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M9 14L12 17L15 14M12 17V11" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-flask" viewBox="0 0 24 24">
    <path d="M9 2H15" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M10 2V8.5L4.7 18A2 2 0 0 0 6.4 21H17.6A2 2 0 0 0 19.3 18L14 8.5V2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M7.5 15H16.5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-flask-vial" viewBox="0 0 24 24">
    <path d="M9 2H15" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M10.5 2V11L5 19A2 2 0 0 0 6.7 22H17.3A2 2 0 0 0 19 19L13.5 11V2" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M7.5 16H16.5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-save" viewBox="0 0 24 24">
    <path d="M5 3H15L19 7V19A2 2 0 0 1 17 21H5A2 2 0 0 1 3 19V5A2 2 0 0 1 5 3Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M8 3V8H15V3" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M8 21V14H16V21" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-gauge" viewBox="0 0 24 24">
    <path d="M4 16A8 8 0 1 1 20 16" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M12 16L15.5 11.5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <circle cx="12" cy="16" r="1.2" fill="currentColor" stroke="none"></circle>
  </symbol>
  <symbol id="hi-key" viewBox="0 0 24 24">
    <circle cx="8" cy="15" r="4.5" stroke="currentColor" stroke-width="1.5"></circle>
    <path d="M11.3 11.7L20 3" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M16.5 7.5L19 5M19 10.5L21 8.5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-lightbulb" viewBox="0 0 24 24">
    <path d="M9 18.5H15" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M10 21.5H14" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M12 3A6.5 6.5 0 0 0 8 14.6C8.6 15.1 9 15.8 9 16.6V17H15V16.6C15 15.8 15.4 15.1 16 14.6A6.5 6.5 0 0 0 12 3Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-search" viewBox="0 0 24 24">
    <circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.5"></circle>
    <path d="M21 21L16.7 16.7" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-search-dollar" viewBox="0 0 24 24">
    <circle cx="11" cy="11" r="7" stroke="currentColor" stroke-width="1.5"></circle>
    <path d="M21 21L16.7 16.7" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M11 7.5V14.5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M13 8.8C12.6 8.3 11.9 8 11 8C9.8 8 8.8 8.7 8.8 9.7C8.8 10.7 9.8 11 11 11.2C12.3 11.4 13.2 11.8 13.2 12.8C13.2 13.8 12.2 14.5 11 14.5C10.1 14.5 9.4 14.2 9 13.7" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-paper-plane" viewBox="0 0 24 24">
    <path d="M21 3L11 13M21 3L14.5 21L11 13L3 9.5L21 3Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-play" viewBox="0 0 24 24">
    <path d="M7 4.5V19.5A1 1 0 0 0 8.5 20.4L19 13.4A1 1 0 0 0 19 11.6L8.5 4.6A1 1 0 0 0 7 4.5Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-plus" viewBox="0 0 24 24">
    <path d="M12 4V20M4 12H20" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-shield" viewBox="0 0 24 24">
    <path d="M12 3L20 6V12C20 17 16.5 20 12 21C7.5 20 4 17 4 12V6Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M12 3V21" stroke="currentColor" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-sliders-2" viewBox="0 0 24 24">
    <path d="M5 21V13M5 9V3M12 21V15M12 11V3M19 21V17M19 13V3" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <circle cx="5" cy="11" r="2" stroke="currentColor" stroke-width="1.5"></circle>
    <circle cx="12" cy="13" r="2" stroke="currentColor" stroke-width="1.5"></circle>
    <circle cx="19" cy="15" r="2" stroke="currentColor" stroke-width="1.5"></circle>
  </symbol>
  <symbol id="hi-table" viewBox="0 0 24 24">
    <rect x="3" y="4" width="18" height="16" rx="2" stroke="currentColor" stroke-width="1.5"></rect>
    <path d="M3 10H21M9 4V20" stroke="currentColor" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-wand-sparkles" viewBox="0 0 24 24">
    <path d="M4 20L20 4" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M9 4V7M7.5 5.5H10.5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M19 13V16M17.5 14.5H20.5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M4 9V11M3 10H5" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-bell" viewBox="0 0 24 24">
    <path d="M6 9A6 6 0 1 1 18 9V13.5L19.5 16.5H4.5L6 13.5V9Z" stroke="currentColor" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M9.5 19A2.5 2.5 0 0 0 14.5 19" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-trash" viewBox="0 0 24 24">
    <path d="M4 7H20" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M9 7V4.5A1.5 1.5 0 0 1 10.5 3H13.5A1.5 1.5 0 0 1 15 4.5V7" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
    <path d="M18.5 7L17.7 19.1A2 2 0 0 1 15.7 21H8.3A2 2 0 0 1 6.3 19.1L5.5 7" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
    <path d="M10 11V17M14 11V17" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-x" viewBox="0 0 24 24">
    <path d="M6 6L18 18M18 6L6 18" stroke="currentColor" stroke-linecap="round" stroke-width="1.5"></path>
  </symbol>
  <symbol id="hi-telegram" viewBox="0 0 24 24">
    <path d="M21 4L2.5 11.5L9 13.5M21 4L17.5 21L9 13.5M21 4L9 13.5M9 13.5V18.5L12 15.5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"></path>
  </symbol>
</svg>"""


_HUGEICON_PATHS = dict(
    _re.findall(
        r'<symbol id="([^"]+)" viewBox="0 0 24 24">(.*?)</symbol>',
        _HUGEICON_SYMBOLS,
        _re.S,
    )
)
def _hi(symbol_id: str, class_name: str = "hi hi-sidebar") -> str:
    paths = _HUGEICON_PATHS.get(symbol_id, "")
    return f'<svg class="{class_name}" viewBox="0 0 24 24" aria-hidden="true" focusable="false">{paths}</svg>'



@_lru_cache(maxsize=512)
def _asset_content_version(path: str, mtime_ns: int, size: int) -> str:
    """Return a content fingerprint, using stat values only as the cache key.

    Deployment systems can normalize every packaged file's modification time, so
    the public URL must be derived from the bytes rather than from ``mtime``.
    """
    del mtime_ns, size
    return _hashlib.sha256(Path(path).read_bytes()).hexdigest()[:12]


def _version_assets(html: str) -> str:
    """Append a content fingerprint to local static asset URLs."""
    def repl(match):
        path = match.group(1)
        rel = path[len("/static/"):]
        try:
            asset = _STATIC_DIR / rel
            stat = asset.stat()
            version = _asset_content_version(
                str(asset), stat.st_mtime_ns, stat.st_size
            )
            return f"{path}?v={version}"
        except OSError:
            return path
    return _re.sub(r'(/static/[^"?\s>]+\.(?:css|js|png|jpg|jpeg|webp|svg))', repl, html)


def _brand_icon_paths() -> tuple[str, str]:
    """Return the shared brand icons used by local and hosted builds."""
    return (
        "/static/icons/realcat-dark.svg",
        "/static/icons/realcat.svg",
    )


def wrap_v4_layout(title: str, content: str, active_page: str, lang: str = "zh", head_extra: str = "") -> str:
    demo_on = demo_mode()
    brand_icon_dark, brand_icon_light = _brand_icon_paths()
    try:
        snapshot = current_snapshot()
        trading_unix = (snapshot.get("broker") or snapshot["trading212"]).get("as_of_unix")
        market_unix = snapshot["market"].get("as_of_unix")
        fundamentals_unix = snapshot["fundamentals"].get("as_of_unix")
    except Exception:
        trading_unix = market_unix = fundamentals_unix = None

    def fmt_time(val):
        if not val:
            return "未刷新"
        return datetime.fromtimestamp(int(val), tz=timezone.utc).astimezone().strftime("%H:%M")

    nav_links = [
        ("/lab", "Portfolio", "hi-lab"),
        ("/returns", "收益对比", "hi-returns"),
        ("/analytics", "分析图表", "hi-trending"),
        ("/strategy", "策略回测", "hi-strategy"),
        ("/heatmap", "持仓热力图", "hi-heatmap"),
        ("/ai", "AI 分析", "hi-ai"),
        ("/import", "导入数据", "hi-import"),
        ("/settings", "系统设置", "hi-settings")
    ]

    links_html = ""
    for href, label, icon in nav_links:
        is_active = "active" if href == active_page else ""
        links_html += f'<a class="nav-link {is_active}" href="{href}"><span class="nav-link-icon">{_hi(icon)}</span>{label}</a>'

    zh_lang_class = "active" if lang == "zh" else ""
    en_lang_class = "active" if lang == "en" else ""
    demo_badge = f'<span class="brand-demo-badge">{_hi("hi-demo", "hi hi-badge")} 假数据</span>' if demo_on else ""
    theme_icon = '<img class="hi hi-sidebar" src="/static/icons/sidebar/theme-light.svg" alt="" width="24" height="24" />'
    menu_icon = _hi("hi-menu", "hi hi-menu-toggle")

    html = f"""<!doctype html>
<html lang="{'en' if lang == 'en' else 'zh-CN'}">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{title} · Catfolio</title>
  <script>
    // Catfolio is light-first; dark is opt-in via the toggle.
    // "system" must be an explicit, stored choice, never the unset default,
    // or this anti-flash check and the runtime three-state toggle disagree
    // and fight each other on machines whose OS reports dark.
    // Applied before render to prevent a flash.
    (function () {{
      var saved = localStorage.getItem("theme");
      var light = saved === "dark" ? false
        : saved === "system" ? (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches)
        : true;
      if (light) {{
        document.documentElement.classList.add("light-theme");
      }}
    }})();
  </script>
  <link rel="stylesheet" href="/static/v4.css" />
  {head_extra}
</head>
<body>
  {_HUGEICON_SYMBOLS}
  <div class="v4-shell">
    <aside class="v4-sidebar">
      <a class="sidebar-brand" href="/">
        <div class="brand-icon" aria-hidden="true">
          <img class="brand-icon-img brand-icon-dark" src="{brand_icon_dark}" alt="" width="36" height="36" />
          <img class="brand-icon-img brand-icon-light" src="{brand_icon_light}" alt="" width="36" height="36" />
        </div>
        <div class="brand-text">
          <span class="brand-name">Catfolio</span>
          <span class="brand-version">投资组合</span>
          {demo_badge}
        </div>
      </a>
      
      <nav class="sidebar-nav">
        {links_html}
      </nav>
      
      <div class="sidebar-footer">
        <button class="theme-toggle-btn" id="themeToggleBtn">
          {theme_icon} <span>深色模式</span>
        </button>

        <div class="language-switcher" aria-label="Language">
          <a class="language-option {zh_lang_class}" href="/set-lang/zh">CN</a>
          <a class="language-option {en_lang_class}" href="/set-lang/en">EN</a>
        </div>

        <div class="sidebar-status-card">
          <div style="font-weight:700;margin-bottom:6px;display:flex;align-items:center;gap:6px;">
            <div class="status-dot"></div> 数据同步状态
          </div>
          <div class="sidebar-status-item"><span>Trading 212:</span> <strong>{fmt_time(trading_unix)}</strong></div>
          <div class="sidebar-status-item"><span>Yahoo 行情:</span> <strong>{fmt_time(market_unix)}</strong></div>
          <div class="sidebar-status-item"><span>FMP 估值:</span> <strong>{fmt_time(fundamentals_unix)}</strong></div>
        </div>
      </div>
    </aside>
    
    <div class="v4-main">
      <header class="v4-topbar">
        <div class="topbar-left">
          <button class="menu-toggle" id="menuToggleBtn" aria-label="Toggle Navigation">{menu_icon}</button>
          <div class="topbar-page-title">{title}</div>
        </div>
        <div class="topbar-right">
          <span class="market-status-badge">
            <div class="status-dot"></div> 账户已连接
          </span>
        </div>
      </header>
      
      <div class="v4-content">
        {content}
      </div>
    </div>
  </div>
  
  <script src="/static/client_i18n.js"></script>
  <script>
    const html = document.documentElement;
    const themeToggleBtn = document.getElementById("themeToggleBtn");

    // Three-state theme: 浅色 → 深色 → 跟随系统 → 浅色.
    // Catfolio is light-first: an unset preference always means light, never
    // an OS lookup. "system" only takes effect once the user explicitly
    // picks it, and is stored as the literal string so it survives reloads.
    const THEME_MODES = ["light", "dark", "system"];
    const THEME_META = {{
      system: ["theme-system.svg", "跟随系统"],
      light: ["theme-light.svg", "浅色模式"],
      dark: ["theme.svg", "深色模式"],
    }};
    function sidebarIcon(filename) {{
      return '<img class="hi hi-sidebar" src="/static/icons/sidebar/' + filename + '" alt="" width="24" height="24" />';
    }}
    function sysLight() {{
      return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches;
    }}
    function currentMode() {{
      const s = localStorage.getItem("theme");
      return (s === "light" || s === "dark" || s === "system") ? s : "light";
    }}
    function applyMode(mode) {{
      localStorage.setItem("theme", mode);
      const light = mode === "light" || (mode === "system" && sysLight());
      html.classList.toggle("light-theme", light);
      const meta = THEME_META[mode];
      themeToggleBtn.innerHTML = sidebarIcon(meta[0]) + ' <span>' + meta[1] + '</span>';
      window.dispatchEvent(new CustomEvent("catfolio:themechange", {{ detail: {{ mode, light }} }}));
    }}
    applyMode(currentMode());

    themeToggleBtn.addEventListener("click", () => {{
      const next = THEME_MODES[(THEME_MODES.indexOf(currentMode()) + 1) % THEME_MODES.length];
      applyMode(next);
    }});

    // Live-follow OS theme changes while in 跟随系统 mode.
    if (window.matchMedia) {{
      window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", (e) => {{
        if (currentMode() === "system") {{
          html.classList.toggle("light-theme", e.matches);
          window.dispatchEvent(new CustomEvent("catfolio:themechange", {{ detail: {{ mode: "system", light: e.matches }} }}));
        }}
      }});
    }}
    
    const menuToggleBtn = document.getElementById("menuToggleBtn");
    const sidebar = document.querySelector(".v4-sidebar");
    
    menuToggleBtn?.addEventListener("click", (e) => {{
      e.stopPropagation();
      sidebar.classList.toggle("open");
    }});
    
    document.addEventListener("click", (e) => {{
      if (sidebar.classList.contains("open") && !sidebar.contains(e.target) && e.target !== menuToggleBtn) {{
        sidebar.classList.remove("open");
      }}
    }});
  </script>
</body>
</html>"""
    return t_block(_version_assets(html), lang)


# ---------------------------------------------------------------------------
# v5 shell — the default collapsible reference-style chrome. The legacy v4 shell
# remains available through `?ui=v4` in render_layout.
# ---------------------------------------------------------------------------

_V5_NAV_GROUPS = [
    ("分析", [
        ("/lab", "Portfolio", "research.svg"),
        ("/returns", "收益对比", "analysis.svg"),
        ("/analytics", "分析图表", "trade.svg"),
        ("/strategy", "策略回测", "strategy.svg"),
        ("/heatmap", "持仓热力图", "tools.svg"),
        ("/ai", "AI 分析", "magic.svg"),
        ("/bank", "银行", "bank.svg"),
    ]),
    ("数据", [
        ("/import", "导入数据", "document.svg"),
        ("/settings", "系统设置", "setting.svg"),
    ]),
]

def wrap_v5_layout(title: str, content: str, active_page: str, lang: str = "zh", head_extra: str = "") -> str:
    demo_on = demo_mode()
    brand_icon_dark, brand_icon_light = _brand_icon_paths()
    page_slug = active_page.strip("/").replace("/", "-") or "home"
    shell_class = "v5-shell collapsed"
    sidebar_mode = "hover"

    groups_html = ""
    for _, items in _V5_NAV_GROUPS:
        links = ""
        for href, label, icon in items:
            is_active = "active" if href == active_page else ""
            icon_html = f'<img class="v5-nav-icon" src="/static/icons/sidebar/{icon}" alt="" width="24" height="24" />'
            links += (
                f'<a class="v5-nav-link {is_active}" href="{href}" title="{label}">'
                f'{icon_html}'
                f'<span class="v5-nav-label">{label}</span></a>'
            )
        groups_html += f'<div class="v5-nav-group">{links}</div>'

    language_group_label = "语言" if lang == "zh" else "Language"
    language_target = "en" if lang == "zh" else "zh"
    language_toggle_text = "CN" if lang == "zh" else "EN"
    language_toggle_label = "切换到英文" if language_target == "en" else "Switch to Chinese"
    demo_brand = '<span class="v5-brand-demo">演示模式</span>' if demo_on else ""

    html = f"""<!doctype html>
<html lang="{'en' if lang == 'en' else 'zh-CN'}">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{title} · Catfolio</title>
  <script>
    (function () {{
      var saved = localStorage.getItem("theme");
      var light = saved === "dark" ? false
        : saved === "system" ? (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches)
        : true;
      if (light) document.documentElement.classList.add("light-theme");
    }})();
  </script>
  <link rel="stylesheet" href="/static/v5.css" />
  {head_extra}
  <link rel="stylesheet" href="/static/design-system.css" />
</head>
<body class="page-{page_slug}">
  {_HUGEICON_SYMBOLS}
  <div class="{shell_class}" id="v5Shell" data-sidebar-mode="{sidebar_mode}">
    <aside class="v5-sidebar" id="v5Sidebar" aria-label="主导航">
      <div class="v5-brand">
        <a class="v5-brand-icon" href="/lab" aria-label="Catfolio">
          <img class="brand-icon-dark" src="{brand_icon_dark}" alt="" width="38" height="38" />
          <img class="brand-icon-light" src="{brand_icon_light}" alt="" width="38" height="38" />
        </a>
        <div class="v5-brand-text">
          <span class="v5-brand-name">Catfolio</span>
          {demo_brand}
        </div>
        <button class="v5-collapse-btn" id="v5CollapseBtn" title="展开侧边栏" aria-label="展开侧边栏" aria-expanded="false">{_hi("hi-menu", "hi")}</button>
      </div>

      <div class="v5-divider"></div>

      <nav class="v5-nav">
        {groups_html}
      </nav>

      <div class="v5-divider"></div>

      <div class="v5-foot">
        <button class="v5-foot-btn" id="themeToggleBtn"><img class="v5-theme-icon" src="/static/icons/sidebar/theme-light.svg" alt="" width="24" height="24" /> <span>浅色模式</span></button>
        <div class="v5-lang" role="group" aria-label="{language_group_label}">
          <a class="v5-lang-toggle" href="/set-lang/{language_target}" aria-label="{language_toggle_label}" title="{language_toggle_label}">{language_toggle_text}</a>
        </div>
        <a class="v5-account" href="/settings">
          <span class="v5-account-mark">{_hi("hi-shield", "hi")}</span>
          <span class="v5-account-copy"><strong>本地工作区</strong><small>数据仅存在这台设备</small></span>
        </a>
      </div>
    </aside>

    <div class="v5-main">
      <div class="v5-content">
        {content}
      </div>
    </div>
  </div>

  <script src="/static/client_i18n.js"></script>
  <script>
    const html = document.documentElement;
    const shell = document.getElementById("v5Shell");
    const sidebar = document.getElementById("v5Sidebar");
    // Desktop uses a hover/focus rail; touch devices keep an explicit toggle.
    const desktopSidebarQuery = window.matchMedia("(hover: hover) and (pointer: fine)");
    let sidebarPointerInside = false;
    function syncSidebarButton() {{
      const collapsed = shell.classList.contains("collapsed");
      const btn = document.getElementById("v5CollapseBtn");
      if (!btn) return;
      btn.setAttribute("aria-label", collapsed ? "展开侧边栏" : "收起侧边栏");
      btn.setAttribute("title", collapsed ? "展开侧边栏" : "收起侧边栏");
      btn.setAttribute("aria-expanded", collapsed ? "false" : "true");
    }}
    function setSidebarCollapsed(collapsed) {{
      shell.classList.toggle("collapsed", collapsed);
      syncSidebarButton();
    }}
    function syncSidebarMode() {{
      if (desktopSidebarQuery.matches) {{
        const keyboardInside = sidebar.contains(document.activeElement);
        setSidebarCollapsed(!sidebarPointerInside && !keyboardInside && !sidebar.matches(":hover"));
      }} else {{
        setSidebarCollapsed(true);
      }}
    }}
    sidebar.addEventListener("pointerenter", () => {{
      sidebarPointerInside = true;
      if (desktopSidebarQuery.matches) setSidebarCollapsed(false);
    }});
    sidebar.addEventListener("pointerleave", () => {{
      sidebarPointerInside = false;
      if (desktopSidebarQuery.matches && !sidebar.contains(document.activeElement)) setSidebarCollapsed(true);
    }});
    sidebar.addEventListener("focusin", () => {{
      if (desktopSidebarQuery.matches) setSidebarCollapsed(false);
    }});
    sidebar.addEventListener("focusout", () => {{
      requestAnimationFrame(() => {{
        if (desktopSidebarQuery.matches && !sidebarPointerInside && !sidebar.contains(document.activeElement)) setSidebarCollapsed(true);
      }});
    }});
    document.getElementById("v5CollapseBtn")?.addEventListener("click", () => {{
      if (!desktopSidebarQuery.matches) setSidebarCollapsed(!shell.classList.contains("collapsed"));
    }});
    document.addEventListener("keydown", (event) => {{
      if (event.key === "Escape" && desktopSidebarQuery.matches) setSidebarCollapsed(true);
    }});
    desktopSidebarQuery.addEventListener?.("change", syncSidebarMode);
    syncSidebarMode();

    // Three-state theme toggle (shared with v4 behaviour).
    const themeToggleBtn = document.getElementById("themeToggleBtn");
    const THEME_MODES = ["light", "dark", "system"];
    const THEME_META = {{ system: ["theme-system.svg", "跟随系统"], light: ["theme-light.svg", "浅色模式"], dark: ["theme.svg", "深色模式"] }};
    function themeIcon(filename) {{ return '<img class="v5-theme-icon" src="/static/icons/sidebar/' + filename + '" alt="" width="24" height="24" />'; }}
    function sysLight() {{ return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches; }}
    function currentMode() {{ const s = localStorage.getItem("theme"); return (s === "light" || s === "dark" || s === "system") ? s : "light"; }}
    function applyMode(mode) {{
      localStorage.setItem("theme", mode);
      const light = mode === "light" || (mode === "system" && sysLight());
      html.classList.toggle("light-theme", light);
      const meta = THEME_META[mode];
      themeToggleBtn.innerHTML = themeIcon(meta[0]) + ' <span>' + meta[1] + '</span>';
      themeToggleBtn.setAttribute("aria-label", meta[1]);
      themeToggleBtn.setAttribute("title", meta[1]);
      window.dispatchEvent(new CustomEvent("catfolio:themechange", {{ detail: {{ mode, light }} }}));
    }}
    applyMode(currentMode());
    themeToggleBtn?.addEventListener("click", () => applyMode(THEME_MODES[(THEME_MODES.indexOf(currentMode()) + 1) % THEME_MODES.length]));
    if (window.matchMedia) {{
      window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", (e) => {{
        if (currentMode() === "system") {{
          html.classList.toggle("light-theme", e.matches);
          window.dispatchEvent(new CustomEvent("catfolio:themechange", {{ detail: {{ mode: "system", light: e.matches }} }}));
        }}
      }});
    }}
  </script>
</body>
</html>"""
    return t_block(_version_assets(html), lang)


def render_layout(request, title: str, content: str, active_page: str, lang: str = "zh", head_extra: str = "") -> str:
    """Use the current v5 shell by default; keep `?ui=v4` as a legacy escape hatch."""
    if request is not None and request.query_params.get("ui") == "v4":
        return wrap_v4_layout(title, content, active_page, lang, head_extra)
    return wrap_v5_layout(title, content, active_page, lang, head_extra)




def data_health_bar(snapshot) -> str:
    """Render a compact data-health indicator bar."""
    broker = snapshot.get("broker") or snapshot["trading212"]
    trading_unix = broker.get("as_of_unix")
    market_unix = snapshot["market"].get("as_of_unix")
    fundamentals_unix = snapshot["fundamentals"].get("as_of_unix")
    fund_rows = len(snapshot["fundamentals"].get("rows", []))
    market_rows = len(snapshot["market"].get("rows", []))
    trading_positions = len(broker.get("positions", []))

    def age_class(unix_val, max_age_sec):
        if not unix_val:
            return "stale"
        age = max(0, int(_time.time()) - int(unix_val))
        if age < max_age_sec:
            return "fresh"
        return "stale"

    t212_class = age_class(trading_unix, 3600)
    market_class = age_class(market_unix, 120)
    fund_class = age_class(fundamentals_unix, 12 * 3600)

    def fmt_age(val):
        if not val:
            return "未刷新"
        age = max(0, int(_time.time()) - int(val))
        if age < 60:
            return f"{age}秒"
        if age < 3600:
            return f"{age//60}分钟"
        return f"{age//3600}小时"

    return f"""<div class="data-health-bar">
  <span class="dh-item {t212_class}"><span class="dh-dot"></span> 持仓 ({trading_positions}个, {fmt_age(trading_unix)})</span>
  <span class="dh-item {market_class}"><span class="dh-dot"></span> 行情 ({market_rows}只, {fmt_age(market_unix)})</span>
  <span class="dh-item {fund_class}"><span class="dh-dot"></span> 估值 ({fund_rows}只, {fmt_age(fundamentals_unix)})</span>
</div>"""
