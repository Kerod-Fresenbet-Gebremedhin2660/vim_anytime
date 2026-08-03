.PHONY: clear-log start

all: clear-log start
clear-log:
	: > /Users/kerod/personal_projects/vim_any/VimAny.log

start:
	tccutil reset Accessibility dev.vimany.VimAny
	open /Users/kerod/personal_projects/vim_any/.build/VimAny.app
