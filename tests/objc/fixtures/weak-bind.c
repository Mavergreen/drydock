extern int weak_def;
__attribute__((weak)) int own_weak = 2;
int *lib_slot = &weak_def;
int *own_slot = &own_weak;
int main(void) { return *lib_slot + *own_slot; }
