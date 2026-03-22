" lobs.vim — plugin entry point
if exists('g:loaded_lobs')
  finish
endif
let g:loaded_lobs = 1

" Set up highlights on colorscheme change
augroup LobsHighlights
  autocmd!
  autocmd ColorScheme * lua require('lobs.ui.highlights').setup()
augroup END

" Initial highlight setup
lua require('lobs.ui.highlights').setup()
