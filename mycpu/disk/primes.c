#include <stdio.h>
int main(void) {
    int n;
    int count = 0;
    printf("=== MyCPU Prime Search ===\n");
    printf("Searching primes from 2 to 1000...\n");
    for (n = 2; n <= 1000; n++) {
        int i;
        int prime = 1;
        for (i = 2; i * i <= n; i++) {
            if (n % i == 0) {
                prime = 0;
                break;
            }
        }
        if (prime) {
            count++;
            if (count % 10 == 0) {
                printf("Found: %d primes\n", count);
            }
        }
    }
    printf("Search complete!\n");
    printf("Total primes: %d\n", count);
    return 0;
}
